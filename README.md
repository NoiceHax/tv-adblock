# tv-adblock

One bash script that debloats an Android TV over Wi-Fi ADB and points it at your own ad-blocking DNS server
(DNS-over-TLS), so the filtering applies to apps that ignore the router's DNS settings.

```
TV_HOST=192.168.1.50 DNS_HOST=dns.example.com SMARTTUBE=1 ./tv-adblock.sh   # apply
TV_HOST=192.168.1.50 ./tv-adblock.sh undo                                     # put everything back
TV_HOST=192.168.1.50 ./tv-adblock.sh status
./tv-adblock.sh rules                                                         # custom DNS rules for Hotstar
./tv-adblock.sh --dry-run                                                     # print changes, make none
```

Run `./tv-adblock.sh --help` for every option. Needs `adb`; `curl` only for SmartTube; `openssl` is used for
the certificate check when present.

## What it does

1. **Debloat** (`DEBLOAT=0` to skip): `pm disable-user` on a short list of packages that are installed. Nothing is
   uninstalled. Packages that were already disabled are not touched by `undo`.
2. **SmartTube** (`SMARTTUBE=1`): installs the stable APK for the TV's CPU from the project's GitHub releases.
3. **Private DNS** (`DNS_HOST=...`): sets Android's Private DNS to your resolver. Before changing anything it
   checks that the name answers on port 853 and that its certificate verifies, because a TV pointed at a dead
   resolver has no internet.

It does not run the DNS server. Use something like AdGuard Home with TLS enabled on a hostname you control.

## What ad blocking by DNS can and cannot do

It works for ads served from their own hostnames. Hotstar is one: `./tv-adblock.sh rules` prints the two hosts.
It does not work for ads stitched into the video stream or served from the same host as the show. In browser
tests, Prime Video and Netflix looked like that, and live sports streams are too.

## Status

The debloat, undo, dry-run and the DNS safety refusal were exercised against a stubbed `adb`. The
SmartTube download and a real switch of Private DNS have not been run from this exact script. Run with
`--dry-run` first. If a TV loses its internet, `./tv-adblock.sh undo` or
`adb shell settings put global private_dns_mode opportunistic` restores it.
