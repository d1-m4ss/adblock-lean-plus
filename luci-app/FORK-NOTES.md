# luci-app-adblock-lean (adblock-lean-plus)

Base: `Wildside-UK/luci-app-adblock-lean` 0.1.0 (commit `4aa149c`, GPL-2.0), written for adblock-lean 0.8.1.
Works with the adblock-lean fork in `../adblock-lean` (upstream `next-version` layout + `adguard_block_lists`), not with adblock-lean 0.8.1.

## Changes against upstream

- **Name**: the pages are titled `Adblock-lean-plus` (menu, headings); service, paths and ubus object keep the upstream names.
- **List names**: subscriptions that are not presets get their name from the AdGuard catalog. For any other URL the user
  can give a name (prefilled from the list's `Title:` header); it is stored after the source in `luci-subscriptions`.
- **Input limits**: sources are an `http(s)` URL (≤ 500, `A-Za-z0-9._~:/?%+@,-`) or a short id; names ≤ 80 characters
  with only `. , : ' ( ) / + & _ -` as ASCII punctuation. Local lists: domains only, comments with the same set plus
  `# *`; the domain check takes a plain domain. All checked in the page and by the backend.
- **Schedule while disabled**: `set_schedule` writes `upd_schedule` but creates no cron job unless the service is enabled.
- **Backup / import** (overview): one JSON file (`adblock-lean-plus-backup`, version 1) with subscriptions, local lists,
  update schedule and start at boot, built and restored through the existing methods; `set_subscriptions` gained
  `dry_run`, so an import is validated as a whole before the first write.
- **Router resources** (overview, `status.resources`): memory of dnsmasq and the DoH proxies, available memory, size and
  place of the blocklist file, free flash space. Read from `/proc` and `df` when the page polls.
- **Backend** (`root/usr/libexec/rpcd/luci.adblock-lean`), rewritten for the next-version layout:
  `global.conf` + `blockset-<id>.conf` (the first blockset), lock in `/tmp/abl-pid`, active blockset found through the
  conf-script in the dnsmasq conf-dir, per-part stats from the session log (`Successfully processed part`).
  State is `active`, `paused`, `stopped` or `busy:<action>`.
- **Subscriptions** (new methods `get_subscriptions`, `set_subscriptions`): a list of `<on/off> <format> <source>` kept in
  `/etc/adblock-lean/luci-subscriptions`; enabled entries are written to `adguard_block_lists`, `raw_block_lists`,
  `hosts_block_lists`, `raw_allow_lists`. Switched-off entries stay in the file. Sources are validated on the router
  (http(s) URLs or short ids per format; no quotes, `$`, `;`, `&`, `|`, `<`, `>`, spaces, backslashes); duplicates and an
  empty set of enabled blocklists are refused; the config is not touched on any error.
- **Local lists** through `get_local`/`set_local` (domains validated on the router) instead of LuCI file access, so the ACL
  grants only the ubus methods of this app.
- **Lists page**: a table of subscriptions (on/off, format, source, delete), ready-made presets (AdGuard DNS filter, Popup
  Hosts, HaGeZi lists in AdGuard syntax incl. full TIF, OISD, StevenBlack) and a custom URL field.
- **Overview page**: states `active` / `paused` / `stopped` / `busy` (paused = RAM metadata still points to the blockset file, read the same way adblock-lean does); Resume only when paused; entries from the metadata `CNT` (no decompression); **automatic update**: Off or daily at a chosen hour (`set_schedule` writes `upd_schedule` in `global.conf` and lets adblock-lean update its cron job; adblock-lean adds a random delay of up to 60 min).
- **Safety of writes**: sources use a character allowlist (no `=`, quotes, `$`, spaces, control characters: they would break adblock-lean's config parser); all list keys are written in one atomic pass; the subscriptions file is re-synced with the config on every read and save (hand/CLI edits win); writes are refused while adblock-lean is busy; temp files via `mktemp`; every write is checked.
- **Local lists**: comments (`#`), empty lines and `*.domain` are kept; both lists are validated (dry run) before anything is saved.
- **Presets** grouped: AdGuard, HaGeZi (short ids = plain-domain lists, no conversion), Security, All-purpose; DNS-suitable picks from yokoffing/filterlists (HaGeZi High-Entropy NRDs 7d, Dandelion Sprout's Anti-Malware in AdGuard Home format, cbuijs HaGeZi combo mini). Browser-only lists (cosmetic, URL parameters, paths) are not offered: measured on the router, e.g. Privacy Essentials 669 lines → 70 usable domains, Actually Legitimate URL Shortener 5841 → 0.
- **Format guess** when a URL is added: `adblock`/AdGuard → AdGuard syntax, `wildcard`/`domains` → plain domains, `hosts` → hosts; dnsmasq-format URLs are refused with an explanation (adblock-lean builds the dnsmasq format itself).

## Install by hand (stand / router)

Use `../install.sh --gui root@<router>`, or by hand:

    scp -O -r luci-app-adblock-lean/root/* root@<router>:/      # -O: OpenWrt's dropbear has no sftp-server
    scp -O -r luci-app-adblock-lean/htdocs/* root@<router>:/www/
    ssh root@<router> 'chmod 755 /usr/libexec/rpcd/luci.adblock-lean; rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache; /etc/init.d/rpcd reload'

Then log out of LuCI and back in: Services → Adblock-lean-plus.

## Cost

The backend runs only while a LuCI page calls it (Overview polls `status` every 5 s). Measured on the stand: see
the README of this repository.
