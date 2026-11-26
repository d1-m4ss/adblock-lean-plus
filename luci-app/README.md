# luci-app-adblock-lean

LuCI pages for [adblock-lean](https://github.com/lynxthecat/adblock-lean) 0.8.x. Tested with adblock-lean 0.8.1 on OpenWrt SNAPSHOT (apk).

## Pages

- **Overview**: whether adblock-lean is active, paused, stopped or busy, how many domains are blocked, when the lists last updated and how long it took, the update schedule and boot setting. Shows each list's entry count and download size from the last update. Buttons to update the lists, pause, resume, stop and enable or disable at boot. A box to check whether a domain would be blocked, and by which entry.
- **Lists**: tick the Hagezi lists you want, add oisd, StevenBlack or URL lists, and edit your local allowlist and blocklist. Save, or Save & Apply to update the lists straight away.
- **Log**: the most recent adblock-lean session log and its system log lines.

## Install

Add the repository and its keys to the router, then install. The second key is a spare, so updates keep working if the signing key ever has to change:

```
echo 'https://raw.githubusercontent.com/Wildside-UK/luci-app-adblock-lean/refs/heads/main/apk/packages.adb' >> /etc/apk/repositories.d/customfeeds.list
wget https://raw.githubusercontent.com/Wildside-UK/luci-app-adblock-lean/refs/heads/main/apk/wildside-uk.pem -O /etc/apk/keys/wildside-uk.pem
wget https://raw.githubusercontent.com/Wildside-UK/luci-app-adblock-lean/refs/heads/main/apk/wildside-uk-backup.pem -O /etc/apk/keys/wildside-uk-backup.pem
apk update
apk add luci-app-adblock-lean
```

Updates then come with `apk upgrade`.

Or install the package on its own, without the repository:

```
wget https://raw.githubusercontent.com/Wildside-UK/luci-app-adblock-lean/refs/heads/main/apk/luci-app-adblock-lean-0.1.0-r1.apk -O /tmp/luci-app-adblock-lean.apk
apk add --allow-untrusted /tmp/luci-app-adblock-lean.apk
```

Log out of LuCI and back in. The pages are under Services, Adblock-lean.

To remove it: `apk del luci-app-adblock-lean`

## Build

With an OpenWrt buildroot or SDK, add this repository as a feed and build `luci-app-adblock-lean` as usual.

Without one, `build.sh` builds the signed apk and the repository index in `apk/` using apk-tools 3 (for example the `apk` from an Image Builder):

```
APK=/path/to/apk KEY=/path/to/private-key ./build.sh
```

## How it works

The rpcd backend (`/usr/libexec/rpcd/luci.adblock-lean`) reads adblock-lean's own files rather than running `service adblock-lean status`. Running status starts a new adblock-lean session, which rotates the session log that holds the per-list counts. The per-list figures from the last update are kept in `/var/run/luci-adblock-lean`.

## Licence

GPL-2.0, the same as adblock-lean.
