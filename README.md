# adblock-lean-plus

DNS ad and tracker blocking for OpenWrt routers, built on
[adblock-lean](https://github.com/lynxthecat/adblock-lean) and dnsmasq, with a LuCI web interface
and encrypted DNS upstreams. A lighter replacement for AdGuard Home on a router.

- **adblock-lean fork** ([`adblock-lean/`](adblock-lean/), changes in [FORK-NOTES](adblock-lean/FORK-NOTES.md)):
  AdGuard-syntax lists (AdGuard DNS filter, AdGuard Home's catalog, HaGeZi `adblock` lists) used directly,
  optional filtering from the first second after boot (`--persist`), survives `sysupgrade`.
- **LuCI app** ([`luci-app/`](luci-app/), changes in [FORK-NOTES](luci-app/FORK-NOTES.md)): subscriptions you can
  switch off without deleting, AdGuard Home's list catalog, format detection, update schedule, status.
- **DoH upstreams** ([`config/https-dns-proxy`](config/https-dns-proxy)): https-dns-proxy with Cloudflare,
  AdGuard (unfiltered) and Quad9, no plain-DNS fallback.

## Screenshots

| Status | Subscriptions | AdGuard Home's list catalog |
|---|---|---|
| [![Status](docs/screenshots/overview.png)](docs/screenshots/overview.png) | [![Subscriptions](docs/screenshots/subscriptions.png)](docs/screenshots/subscriptions.png) | [![Catalog](docs/screenshots/adguard-catalog.png)](docs/screenshots/adguard-catalog.png) |

The pages are rendered from this repository's view files with data captured from a test router
(LuCI default theme).

## Compared with AdGuard Home

Measured on one router: GL.iNet GL-MT6000 (4 × Cortex-A53, 1 GB RAM), OpenWrt 25.12, AdGuard Home 1.0.0,
the same seven blocklists in both (AdGuard DNS filter, AdGuard Popup Hosts, HaGeZi Pro++, TIF medium,
three HaGeZi "native" lists), DoH upstreams in both. adblock-lean-plus ran on a second dnsmasq instance
next to AdGuard Home; DNS benchmark: 3 × 1000 queries per category from a LAN client.

| | AdGuard Home | adblock-lean-plus |
|---|---|---|
| Blocking result on a 2011-domain test set | reference | identical (incl. 203 exceptions and 8 custom blocks) |
| Memory (RSS) | 162–235 MB (0.107.x: up to 483 MB) | **52 MB** (dnsmasq 46 + DoH proxies 6) |
| With HaGeZi TIF full (1.1M domains) | HaGeZi recommends ≥ 2 GB RAM | dnsmasq 110 MB; ≥ 428 MB stayed free during updates |
| Cached answer, median / p95 | 3 / 5 ms | 2 / 3 ms |
| Blocked domain, median / p95 | 3–4 / 4–7 ms | 2 / 3 ms |
| Uncached queries | depends on upstream | the same (same DoH upstreams) |
| List update (7 lists, BusyBox only) | in the background | 51 s (TIF full: 140 s), once a day |
| Filtering right after boot | yes | with `--persist` (early boot script); otherwise after the lists are loaded |
| Web UI cost | always running | none unless a page is open; no measurable effect on DNS latency |
| Query log, statistics, per-client rules | yes | no |

What you lose: AdGuard Home's query log, statistics and per-client settings. Blocking is silent: dnsmasq
does not log queries, adblock-lean logs only its own updates.

## Requirements

- OpenWrt with dnsmasq 2.86 or newer (OpenWrt 23.05+), `apk` or `opkg`.
- About 6 MB free on `/overlay` (+15 MB with `--persist`). The list preset follows the router's RAM, as in adblock-lean:
  mini (64 MB), small (128 MB), medium (256 MB), large (512 MB), huge (1 GB: HaGeZi Pro + TIF full).
- LuCI for the web pages (optional).

## Install

From a computer with SSH access to the router:

```sh
git clone <repository URL> adblock-lean-plus && cd adblock-lean-plus
./install.sh --dry-run root@192.168.1.1     # check the router, change nothing
./install.sh --gui --doh root@192.168.1.1   # blocker + LuCI pages + DoH proxies
```

| Option | What it does |
|---|---|
| *(none)* | the blocker only: scripts, configs, dnsmasq `addnmount` entries |
| `--gui` | LuCI pages: Services → Adblock-lean |
| `--doh` | `apk update` (or `opkg update`), then https-dns-proxy with the three DoH upstreams (config written first, so the package leaves dnsmasq and the firewall alone; an existing config is kept only if it is equally safe) |
| `--doh-gui` | also `luci-app-https-dns-proxy` to edit the DoH upstreams in LuCI |
| `--preset NAME` | mini, small, medium, large or huge (default: chosen from RAM) |
| `--lists adguard` | add AdGuard DNS filter and AdGuard Popup Hosts to the preset's HaGeZi lists |
| `--persist` | keep the blockset on flash: filtering right after boot, but several MB rewritten on every update (good for eMMC/SSD/USB) |
| `--instance NAME` | dnsmasq instance to filter (needed only when there are several) |
| `--start`, `--enable` | download the lists now; start at boot |
| `--upgrade` | replace the scripts of an existing installation, keep configs |

SSH options go in `SSH_OPTS`, e.g. `SSH_OPTS="-p 2222" ./install.sh ...`; one SSH connection is reused for all steps.

The installer does not change dnsmasq's port or upstream servers and does not touch the firewall. At the
end it prints the `uci` commands that point dnsmasq at the DoH proxies.

## If you already run AdGuard Home

AdGuard Home (AGH) and adblock-lean-plus both want to be the router's DNS on port 53, so AGH goes first.
Two common AGH setups exist; check yours with `netstat -lntup | grep ':53 '`:

- **AGH on port 53**, dnsmasq moved to another port (e.g. 54) and used by AGH for local names. Most guides do this.
- **dnsmasq on port 53**, forwarding to AGH (e.g. `server=127.0.0.1#5353` or DHCP option 6 pointing clients to AGH).

### 1. Note what to carry over

Save the AGH config first (`/etc/adguardhome/adguardhome.yaml`, older packages: `/etc/adguardhome.yaml`) and note:

| In AGH | In adblock-lean-plus |
|---|---|
| Blocklists (Filters → DNS blocklists) | the same URLs: LuCI → Adblock-lean → Subscriptions → "AdGuard catalog…" or "Add URL" (format is detected), or `install.sh --lists adguard` for AdGuard DNS filter + Popup Hosts |
| Allowlists, custom `@@` rules | local allowlist (Subscriptions page) |
| Disallowed domains, custom block rules | local blocklist (Subscriptions page) |
| DNS rewrites | `uci add_list dhcp.@dnsmasq[0].address='/name/ip'` |
| Upstream DNS (DoH) | `--doh` (Cloudflare, AdGuard unfiltered, Quad9) or your own in `/etc/config/https-dns-proxy` |
| Domain-specific upstreams `[/domain/]ip` | `uci add_list dhcp.@dnsmasq[0].server='/domain/ip'` |
| Query log, statistics, per-client rules | not available |

### 2. Give port 53 back to dnsmasq

Do this from a wired or Wi-Fi client you can test with, and keep a way back (AGH stays installed until step 4).

```sh
/etc/init.d/adguardhome stop
uci -q delete dhcp.@dnsmasq[0].port          # AGH-on-53 setup: dnsmasq back to port 53
uci -q delete dhcp.@dnsmasq[0].server        # drop forwards to AGH / old upstream entries
uci set dhcp.@dnsmasq[0].noresolv='0'        # for now use the WAN's DNS servers
uci set dhcp.@dnsmasq[0].cachesize='10000'   # AGH setups often set 0 (AGH did the caching)
uci commit dhcp && /etc/init.d/dnsmasq restart
```

If DHCP option 6 or a firewall redirect points clients to AGH's address or port, point it at the router / port 53.
Open a few sites from a client. If something fails: `/etc/init.d/adguardhome start` and restore the old values.

### 3. Remove AdGuard Home

```sh
/etc/init.d/adguardhome disable
apk del adguardhome                     # opkg: opkg remove adguardhome
rm -rf /etc/adguardhome /var/lib/adguardhome   # config and work dir (query log), after your backup
```

### 4. Install adblock-lean-plus

```sh
./install.sh --gui --doh --start --enable root@<router>
```

Run the `uci` commands it prints to switch dnsmasq to the DoH proxies, add your lists from step 1 on the
Subscriptions page, then check from a client: `nslookup doubleclick.net` → no address (NXDOMAIN, with lists that
block it), normal sites resolve.

**No-gap variant:** install first with `--instance <dnsmasq instance> --start` while AGH still answers (the lists load
into dnsmasq on its other port), then do steps 2–3; filtering starts the moment dnsmasq takes port 53.

## Firewall (optional)

adblock-lean-plus needs no firewall changes: clients use the router as DNS (DHCP option 6) and dnsmasq filters.
Devices with a hard-coded DNS server (e.g. 8.8.8.8) bypass it; a redirect sends their plain DNS to the router:

```sh
uci set firewall.dns_redirect=redirect
uci set firewall.dns_redirect.name='Force-DNS-to-router'
uci set firewall.dns_redirect.src='lan'
uci set firewall.dns_redirect.src_dport='53'
uci set firewall.dns_redirect.dest_port='53'
uci set firewall.dns_redirect.proto='tcp udp'
uci set firewall.dns_redirect.target='DNAT'
uci commit firewall && /etc/init.d/firewall reload
```

Encrypted DNS inside apps and browsers (DoH/DoT) can not be redirected; the HaGeZi "Encrypted DNS/VPN/Proxy bypass"
preset blocks the names of public DoH servers, so most browsers fall back to the router.

## DoH upstreams

[`config/https-dns-proxy`](config/https-dns-proxy) runs three proxies on `127.0.0.1:5053/5054/5055`. dnsmasq sends
each query to the fastest of them and re-tests the others from time to time, so one failing proxy is skipped; there is
deliberately no plain-DNS fallback (dnsmasq has no "fallback only" mode, so a plain server would also get normal
traffic). Each proxy resolves its DoH host through
its `bootstrap_dns` addresses only.

To change them: LuCI → Services → HTTPS DNS Proxy (`--doh-gui`), or edit `/etc/config/https-dns-proxy` and
`/etc/init.d/https-dns-proxy restart`. Keep `dnsmasq_config_update '-'` unless you want the package to rewrite dnsmasq.

## Lists

- **Formats:** AdGuard syntax (`||domain^`, `@@` exceptions, `$important`, `$badfilter`, blocking `$dnsrewrite`),
  plain domains, hosts files. dnsmasq-format lists are refused (adblock-lean builds that itself).
- **Browser lists do not work over DNS.** uBlock Origin lists (cosmetic rules, URL parameters, paths) give almost
  nothing: e.g. 70 usable rules out of 669 in "Privacy Essentials". The LuCI page checks a URL's content when you add
  it and warns or refuses.
- Rules that dnsmasq can not express are skipped and counted in the log: wildcards inside a name, regexes,
  `$client`/`$denyallow` and similar, whole-TLD rules (`||xyz^`). `.example.com^` blocks `example.com` too.
- HaGeZi lists are fastest as adblock-lean short ids (`hagezi:pro.plus`, plain domains): no conversion needed.

## Updating

- `./install.sh --upgrade root@<router>` replaces the scripts and keeps the configs.
- Upstream changes: `tools/sync-upstream.sh` pulls adblock-lean (`next-version`) and the LuCI app (`main`) into
  their subtrees; resolve conflicts, run `sh adblock-lean/tests/test-list-conv.sh`, test on a router.
- adblock-lean's own `update` command is disabled in this fork: it would replace the fork with the upstream version.
- The `luci-app/` subtree's upstream package feed and `.apk` are not used: that build is for adblock-lean 0.8.x.

## Uninstall

If dnsmasq uses the DoH proxies, give it other upstreams first, or DNS stops when the proxies are removed:

```sh
ssh root@<router> 'uci -q del dhcp.@dnsmasq[0].server; uci -q del dhcp.@dnsmasq[0].noresolv; uci commit dhcp; /etc/init.d/dnsmasq restart'
```

Then:

```sh
ssh root@<router> '/etc/init.d/adblock-lean uninstall'
ssh root@<router> 'rm -rf /usr/libexec/rpcd/luci.adblock-lean /usr/share/rpcd/acl.d/luci-app-adblock-lean.json \
  /usr/share/luci/menu.d/luci-app-adblock-lean.json /www/luci-static/resources/view/adblock-lean; /etc/init.d/rpcd reload'
ssh root@<router> 'apk del https-dns-proxy luci-app-https-dns-proxy'      # opkg: opkg remove luci-app-https-dns-proxy https-dns-proxy
ssh root@<router> 'rm -rf /etc/adblock-lean /etc/config/https-dns-proxy'  # remaining configs, if not needed
```

`uninstall` stops filtering and removes the scripts, the boot hooks, the saved blockset and the dnsmasq `addnmount`
entries; it keeps the configs in `/etc/adblock-lean`.

## Tests

`sh adblock-lean/tests/test-list-conv.sh` (run on the router or with BusyBox): list sanitizing and AdGuard-syntax
conversion, 21 checks.

## Credits and licence

- [adblock-lean](https://github.com/lynxthecat/adblock-lean) by lynxthecat, friendly-bits and contributors (GPL-2.0).
- [luci-app-adblock-lean](https://github.com/Wildside-UK/luci-app-adblock-lean) by Wildside-UK (GPL-2.0).
- [https-dns-proxy](https://github.com/aarond10/https_dns_proxy) and its OpenWrt package (installed from the OpenWrt feeds).
- Blocklists belong to their authors (AdGuard, HaGeZi and others) and keep their own licences.

This repository is GPL-2.0 ([LICENSE](LICENSE)).
