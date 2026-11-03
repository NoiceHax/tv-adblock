#!/usr/bin/env bash
# tv-adblock.sh - debloat an Android TV over Wi-Fi ADB and point it at your own ad-blocking DNS.
#
#   TV_HOST=192.168.1.50 DNS_HOST=dns.example.com ./tv-adblock.sh            # apply
#   TV_HOST=192.168.1.50 ./tv-adblock.sh undo                                # put everything back
#   TV_HOST=192.168.1.50 ./tv-adblock.sh status                              # show what is changed
#
# What "apply" does, in order. Every step is optional and every step is reversible with "undo":
#   1. Debloat: `pm disable-user` on a short list of packages that are installed on this TV. Nothing is
#      uninstalled, and a package that was already disabled is left out of the undo list.
#   2. SmartTube (SMARTTUBE=1): download the stable APK matching the TV's CPU from the project's
#      GitHub releases and install it. It does not touch the stock YouTube app.
#   3. Private DNS (DNS_HOST=...): switch Android's Private DNS (DNS-over-TLS) to DNS_HOST. This is the
#      step that makes network-wide DNS blocking stick: a TV that ignores the router's DNS setting
#      (Google DNS hard-coded, IPv6 router advertisements) still has to use the resolver set here.
#      It turns on automatic time first and checks the TV clock: with a wrong clock the certificate looks
#      "not yet valid" or expired, every lookup fails, and the TV cannot even fetch the time to fix itself.
#
# What it does NOT do: it does not run the DNS server for you. DNS_HOST must already answer DNS-over-TLS on
# port 853 with a certificate that is valid for that exact name (AdGuard Home does this once TLS is set up
# in its settings). Before touching the TV the script checks that the port answers and that the
# certificate verifies, because a TV pointed at a dead resolver has no internet at all.
#
# Ad blocking that this can and cannot do:
#   * It can block ads that are served from their own hostnames. Hotstar is one: add these to the DNS
#     server's custom rules (print them with `./tv-adblock.sh rules`):  ||hesads.akamaized.net^  and
#     ||shifu.hotstarext.com^
#   * It cannot block ads that are stitched into the video stream or served from the same host as the
#     show. Prime Video and Netflix looked like that when tested in a browser, and live sports streams are
#     too. No hostname filter separates those.
#
# Needs: adb on PATH (or ADB=/path/to/adb); curl only for SMARTTUBE=1; openssl is used for the
# certificate check when present. The TV needs "USB debugging" / "Network debugging" turned on, and you
# accept the ADB prompt on the TV the first time.
#
# Environment:
#   TV_HOST       required. The TV's IP address (or ip:port; the port defaults to 5555).
#   DNS_HOST      DNS-over-TLS hostname for the Private DNS step. Unset: that step is skipped.
#   SMARTTUBE     1 to install SmartTube. Default: not installed.
#   DEBLOAT       0 to skip the debloat step. Default: 1.
#   EXTRA_DISABLE space-separated extra packages to disable (e.g. a stock launcher you replaced).
#   YES           1 to skip the confirmation prompt (needed when there is no terminal).
#   DRY_RUN       1 (or --dry-run) prints every command that would change the TV and runs none of them.
#   FORCE         1 to carry on when the DoT port or certificate check fails. Use with care.
#   ADB           the adb binary. Default: adb.
#   STATE_DIR     where the undo list is kept. Default: ${XDG_STATE_HOME:-~/.local/state}/tv-adblock.
set -euo pipefail

ADB="${ADB:-adb}"
DEBLOAT="${DEBLOAT:-1}"
SMARTTUBE="${SMARTTUBE:-0}"
YES="${YES:-0}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
DNS_HOST="${DNS_HOST:-}"
EXTRA_DISABLE="${EXTRA_DISABLE:-}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tv-adblock}"

# Packages that are safe to disable on most Google TV / Android TV sets. Sony-only ones are skipped on
# other brands. Anything not installed on this TV is skipped automatically. Keep this list to things that
# have nothing to do with playing video or reaching the launcher; if a TV behaves oddly, `undo` re-enables all.
DEBLOAT_LIST=(
  com.google.android.play.games       # Play Games
  com.google.android.videos           # Google TV movie store
  com.google.android.backdrop         # ambient-mode screensaver
  com.google.android.feedback         # feedback service
  com.android.camera2                 # camera app (no camera on most TVs)
  com.android.gallery3d               # gallery
  com.android.printspooler            # print spooler
  com.android.htmlviewer              # HTML viewer
)
SONY_LIST=(
  com.sony.dtv.demo                   # store demo mode
  com.sony.dtv.smarthelp              # help guide
  com.sony.dtv.helpguidecontents
  com.sony.dtv.eulaviewer             # EULA viewer
)

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

CMD=apply
for a in "$@"; do
  case "$a" in
    apply|undo|status|rules) CMD=$a ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help|help) usage 0 ;;
    *) echo "unknown argument: $a" >&2; usage 1 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [ "$CMD" = rules ]; then
  say "# Add these to your DNS server's custom filtering rules (AdGuard Home: Filters > Custom filtering rules)."
  say "# They were found by watching Hotstar's requests; both are ad-only hosts."
  say "||hesads.akamaized.net^"
  say "||shifu.hotstarext.com^"
  exit 0
fi

: "${TV_HOST:?set TV_HOST to the TV IP address, e.g. TV_HOST=192.168.1.50 $0}"
case "$TV_HOST" in *:*) SERIAL=$TV_HOST ;; *) SERIAL=$TV_HOST:5555 ;; esac
command -v "$ADB" >/dev/null 2>&1 || die "adb not found. Install Android platform-tools or set ADB=/path/to/adb."

# Reads (getprop, pm list, settings get) always run. Anything that changes the TV goes through mutate(),
# which only prints in a dry run.
tv()     { "$ADB" -s "$SERIAL" shell "$@" 2>&1 | tr -d '\r'; }
mutate() {
  if [ "$DRY_RUN" = 1 ]; then say "[dry run] adb shell $*"; return 0; fi
  "$ADB" -s "$SERIAL" shell "$@" 2>&1 | tr -d '\r'
}

UNDO_FILE="$STATE_DIR/$(printf '%s' "$SERIAL" | tr -c 'A-Za-z0-9._-' '_').undo"
recorded() { [ -f "$UNDO_FILE" ] && grep -q "^$1 " "$UNDO_FILE"; }
record() {
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$*" >> "$UNDO_FILE"
}

# ---- connect -------------------------------------------------------------------------------------
say "Connecting to $SERIAL ..."
"$ADB" connect "$SERIAL" >/dev/null 2>&1 || true
if ! timeout 20 "$ADB" -s "$SERIAL" wait-for-device >/dev/null 2>&1; then
  die "could not reach $SERIAL. Is the TV on (not asleep), on the same network, with network debugging enabled?"
fi
STATE=$("$ADB" -s "$SERIAL" get-state 2>&1 || true)
[ "$STATE" = device ] || die "adb state is '$STATE'. If it says 'unauthorized', accept the debugging prompt on the TV and run again."

SDK=$(tv getprop ro.build.version.sdk | tr -dc '0-9')
MODEL=$(tv getprop ro.product.model)
BRAND=$(tv getprop ro.product.brand | tr '[:upper:]' '[:lower:]')
ABI=$(tv getprop ro.product.cpu.abi)
RELEASE=$(tv getprop ro.build.version.release)
say "TV: $BRAND $MODEL, Android $RELEASE (SDK ${SDK:-?}), $ABI"

# ---- status --------------------------------------------------------------------------------------
if [ "$CMD" = status ]; then
  say "Private DNS mode:      $(tv settings get global private_dns_mode)"
  say "Private DNS hostname:  $(tv settings get global private_dns_specifier)"
  say "Automatic time:        $(tv settings get global auto_time)   (1 = on)"
  say "TV clock:              $(tv date)   (this machine: $(date))"
  say "Disabled packages (all, not only ours):"
  tv pm list packages -d | sed 's/^package:/  /'
  [ -f "$UNDO_FILE" ] && say "Undo list: $UNDO_FILE" || say "No undo list for this TV in $STATE_DIR."
  exit 0
fi

# ---- undo ----------------------------------------------------------------------------------------
if [ "$CMD" = undo ]; then
  [ -f "$UNDO_FILE" ] || warn "no undo list at $UNDO_FILE; will restore Private DNS to Android's default only."
  if [ -f "$UNDO_FILE" ]; then
    while read -r kind a b; do
      case "$kind" in
        disabled) say "re-enable $a"; mutate pm enable "$a" >/dev/null ;;
        dns_mode)
          say "Private DNS mode back to: $a"
          if [ "$a" = null ]; then mutate settings delete global private_dns_mode >/dev/null
          else mutate settings put global private_dns_mode "$a" >/dev/null; fi ;;
        dns_spec)
          if [ "$a" = null ]; then mutate settings delete global private_dns_specifier >/dev/null
          else mutate settings put global private_dns_specifier "$a" >/dev/null; fi ;;
        auto_time)
          say "automatic time back to: $a"
          if [ "$a" = null ]; then mutate settings delete global auto_time >/dev/null
          else mutate settings put global auto_time "$a" >/dev/null; fi ;;
        smarttube) say "SmartTube ($a) was installed by this script; remove it yourself if you want: adb uninstall $a" ;;
      esac
    done < "$UNDO_FILE"
    [ "$DRY_RUN" = 1 ] || mv "$UNDO_FILE" "$UNDO_FILE.done-$(date +%s)"
  else
    mutate settings put global private_dns_mode opportunistic >/dev/null
  fi
  say "Undone."
  exit 0
fi

# ---- apply: plan ---------------------------------------------------------------------------------
[ -n "$SDK" ] || die "the TV did not report its SDK level; is adb really talking to it?"
INSTALLED=$(tv pm list packages)
ALREADY_OFF=$(tv pm list packages -d)
has_pkg()  { printf '%s\n' "$INSTALLED"   | grep -qx "package:$1"; }
is_off()   { printf '%s\n' "$ALREADY_OFF" | grep -qx "package:$1"; }

TO_DISABLE=()
if [ "$DEBLOAT" = 1 ]; then
  cands=("${DEBLOAT_LIST[@]}")
  [ "$BRAND" = sony ] && cands+=("${SONY_LIST[@]}")
  for p in "${cands[@]}"; do
    has_pkg "$p" || continue
    is_off "$p" && continue
    TO_DISABLE+=("$p")
  done
  for p in $EXTRA_DISABLE; do
    has_pkg "$p" || { warn "EXTRA_DISABLE: $p is not installed here; skipping."; continue; }
    is_off "$p" && continue
    TO_DISABLE+=("$p")
  done
fi

DO_DNS=0
if [ -n "$DNS_HOST" ]; then
  [ "$SDK" -ge 28 ] || die "Private DNS needs Android 9 (SDK 28) or newer; this TV is SDK $SDK. Unset DNS_HOST to run the other steps."
  DO_DNS=1
fi

say
say "Plan for $BRAND $MODEL ($SERIAL):"
if [ "${#TO_DISABLE[@]}" -gt 0 ]; then say "  disable ${#TO_DISABLE[@]} packages: ${TO_DISABLE[*]}"
else say "  debloat: nothing to do"; fi
[ "$SMARTTUBE" = 1 ] && say "  install SmartTube (stable, $ABI) from github.com/yuliskov/SmartTube"
[ "$DO_DNS" = 1 ] && say "  Private DNS -> $DNS_HOST (DNS-over-TLS)"
[ "$DO_DNS" = 1 ] && say "  automatic time on, and the TV clock checked against this machine's first"
[ "$DO_DNS" = 0 ] && [ -z "$DNS_HOST" ] && say "  Private DNS: skipped (DNS_HOST not set)"
[ "$DRY_RUN" = 1 ] && say "  (dry run: nothing will be changed)"
say "  undo list: $UNDO_FILE"

if [ "$YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
  [ -t 0 ] || die "no terminal to ask on; run again with YES=1 to confirm."
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) say "Nothing changed."; exit 0 ;; esac
fi

# ---- apply: DNS preflight (before anything is changed) -------------------------------------------
if [ "$DO_DNS" = 1 ]; then
  if ! timeout 6 bash -c "exec 3<>/dev/tcp/$DNS_HOST/853" 2>/dev/null; then
    msg="$DNS_HOST does not answer on TCP 853 from this machine (is DNS-over-TLS on, and the name resolvable here?)"
    [ "$FORCE" = 1 ] && warn "$msg; FORCE=1, carrying on." || die "$msg. The TV would lose DNS. Nothing was changed."
  fi
  if command -v openssl >/dev/null 2>&1; then
    CHECK=$(timeout 10 openssl s_client -connect "$DNS_HOST:853" -servername "$DNS_HOST" -verify_hostname "$DNS_HOST" -verify_return_error </dev/null 2>&1 || true)
    if ! printf '%s' "$CHECK" | grep -q 'Verification: OK'; then
      msg="the certificate on $DNS_HOST:853 does not verify for that name"
      [ "$FORCE" = 1 ] && warn "$msg; FORCE=1, carrying on." || die "$msg. Android's hostname mode would refuse it and the TV would lose DNS. Nothing was changed."
    fi
  else
    warn "openssl not found; could not check the certificate. A bad certificate leaves the TV without DNS."
  fi
fi

# ---- apply: do it --------------------------------------------------------------------------------
if [ "${#TO_DISABLE[@]}" -gt 0 ]; then
  for p in "${TO_DISABLE[@]}"; do
    out=$(mutate pm disable-user --user 0 "$p")
    case "$out" in
      *"new state: disabled"*|"[dry run]"*) say "disabled $p"; record disabled "$p" ;;
      *) warn "could not disable $p: $out" ;;
    esac
  done
fi

if [ "$SMARTTUBE" = 1 ]; then
  command -v curl >/dev/null 2>&1 || die "SMARTTUBE=1 needs curl."
  say "Looking up the latest SmartTube release ..."
  REL=$(curl -fsSL https://api.github.com/repos/yuliskov/SmartTube/releases/latest) || die "could not read the SmartTube release list (GitHub rate limit or no internet?)."
  URLS=$(printf '%s' "$REL" | grep -o '"browser_download_url": *"[^"]*\.apk"' | cut -d'"' -f4)
  # The first CPU ABI the TV reports decides which build we want. Stable builds only, never beta.
  URL=$(printf '%s\n' "$URLS" | grep -i 'stable' | grep -i -- "$ABI" | head -n 1 || true)
  if [ -z "$URL" ]; then
    warn "no stable SmartTube APK matched ABI '$ABI'. The release has:"
    printf '%s\n' "$URLS" | sed 's/^/  /' >&2
    die "pick one and install it yourself: adb -s $SERIAL install -r <apk>"
  fi
  say "Downloading $URL"
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/smarttube.apk" "$URL" || die "download failed."
  if [ "$DRY_RUN" = 1 ]; then say "[dry run] adb install -r smarttube.apk"
  else
    OUT=$("$ADB" -s "$SERIAL" install -r "$TMP/smarttube.apk" 2>&1 | tr -d '\r')
    printf '%s\n' "$OUT"
    case "$OUT" in *Success*) record smarttube org.smarttube.stable ;; *) die "SmartTube install failed (see above). Nothing after this step was run." ;; esac
  fi
fi

if [ "$DO_DNS" = 1 ]; then
  # A TV whose clock is wrong rejects the DoT certificate (not valid yet, or expired) and then has no DNS at
  # all, so it cannot even fetch the time to repair itself. Turn automatic time on while the current DNS
  # still works, wait for the clock to agree with this machine's, and only then switch.
  if [ "$(tv settings get global auto_time)" != 1 ]; then
    recorded auto_time || record auto_time "$(tv settings get global auto_time)"
    mutate settings put global auto_time 1 >/dev/null
    say "Turned on automatic time."
  fi
  skew=0
  if [ "$DRY_RUN" != 1 ]; then
    for _ in $(seq 1 12); do
      tv_now=$(tv date +%s | tr -dc '0-9')
      skew=$(( $(date +%s) - ${tv_now:-0} )); skew=${skew#-}
      [ "$skew" -le 300 ] && break
      sleep 5
    done
  fi
  if [ "$skew" -gt 300 ]; then
    msg="the TV clock is about $(( skew / 3600 )) hours away from this machine's even with automatic time on (TV says: $(tv date))"
    [ "$FORCE" = 1 ] && warn "$msg; FORCE=1, carrying on." || die "$msg. With a wrong clock the certificate check fails and the TV would lose DNS. Set the TV's date and time, then run again. Private DNS was not changed."
  fi
  # Remember what was there before the first run, and never overwrite it on later runs.
  recorded dns_mode || record dns_mode "$(tv settings get global private_dns_mode)"
  recorded dns_spec || record dns_spec "$(tv settings get global private_dns_specifier)"
  mutate settings put global private_dns_specifier "$DNS_HOST" >/dev/null
  mutate settings put global private_dns_mode hostname >/dev/null
  say "Private DNS set to $DNS_HOST."
  say "If the TV ever has no internet: TV_HOST=$TV_HOST $0 undo   (or: adb -s $SERIAL shell settings put global private_dns_mode opportunistic)"
fi

say
say "Done. Check the DNS server's query log while you use the TV: your TV's address should show up as client,"
say "and queries should arrive as DNS-over-TLS. Then add the ad hosts you find to its custom rules."
say "Hotstar's two: run '$0 rules'."
