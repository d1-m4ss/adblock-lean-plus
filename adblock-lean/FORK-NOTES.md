# adblock-lean (adblock-lean-plus fork)

Base: upstream `lynxthecat/adblock-lean`, branch `next-version`, commit `1c1346e` (2026-09-30, unreleased).

## Changes against upstream

| Change | Upstream issue | Files |
|---|---|---|
| New list format `adguard` (option `adguard_block_lists`): AdGuard DNS filtering syntax converted to raw domains; `@@` exceptions go to the blockset allowlist; `important`, `badfilter`, blocking `dnsrewrite` supported; unsupported rules skipped and counted in the log | — | `usr/lib/adblock-lean/abl-process.sh`, `abl-lib.sh`, `abl-manage.sh`, `README.md` |
| AdGuard exceptions are safe by construction: not merged in whitelist mode; an exception never covers a domain (or a parent of a domain) from the local blocklist; `important` block rules (not disabled by `badfilter`) survive exceptions for parent domains; uppercase modifiers, CRLF lists handled; hosts lines only in the blocking `0.0.0.0`/`::` forms; IP-address rules and `localhost` names skipped | — | `abl-process.sh` |
| AdGuard `.example.com^` rules become `example.com` (no `*.` wildcard entries): on a GL.iNet GL-MT6000 with dnsmasq 2.93, 7 wildcard `local=/*.x/` lines in a 567k-domain blockset raised the average uncached lookup from ~78 ms to ~210 ms; removing them restored ~78 ms | — | `abl-process.sh` |
| Faster AdGuard conversion: fast path for `||domain^`, second pass only when the list has `badfilter`/`important` rules (PRO++: 29 s → 16 s with busybox awk) | — | `abl-process.sh` |
| All formats: strip UTF-8 BOM, drop lines starting with `!` or `[` (`[Adblock Plus]` headers) and cosmetic rules (`example.com##.ad`) | #210, #195 | `abl-process.sh` |
| Hagezi `-onlydomains` URL check no longer rejects NRD/DGA lists | #225 | `abl-process.sh` |
| Local block/allow lists are processed once (as raw), not once per list format | — | `abl-process.sh` |
| Early boot script `/etc/init.d/adblock-lean-early` (START=18, before dnsmasq): restores the conf-script of a persistent blockset whose md5 matches, so dnsmasq filters from its own start. `boot-cs.<id>` is saved only after the blockset passed the active checks, dropped on install failure, on `rm_blockset_config` and uninstall; blocksets without a config or with changed conf-dirs are not restored; the state check accepts the 'loaded by the early script, no RAM metadata yet' state (`11010`); the script is rewritten on start when its template changes | #226 | `adblock-lean`, `abl-manage.sh` |
| `/lib/upgrade/keep.d/adblock-lean` while enabled: sysupgrade with kept settings preserves scripts, config, enabled state and the early boot script; also the LuCI pages, the list status, the `boot-cs.<id>` files and a persistent blockset dir that is on the root filesystem (one on another mount survives by itself), so the early boot script filters from the first boot | #124, #211 | `adblock-lean` |
| `ABL_UPD_CHANNEL=local-fork`: upstream update check off, `update` refuses to run (it would replace the fork) | — | `adblock-lean` |
| Tests: `tests/test-list-conv.sh`, `tests/test-list-retry.sh` (run with busybox; `tools/ci.sh` of the repository runs them all) | — | `tests/` |

## List status for the web interface

After the parts of an update are processed, the result of every list is written to `/etc/adblock-lean/list-status`
(`list <ok|fail> <last attempt> <last good> <entries> <reason> <list>`; reasons: `http_<code>`, `net`, `content`, `few`,
`size`, `timeout`, `error`), and at the end of `start` a `run <time> <0|1>` line says whether newly generated lists got installed.
Entries of lists not processed for 30 days are dropped. On flash because the logs are in RAM and are rotated on every
start. A write that fails never fails the update. Files: `abl-process.sh` (`save_list_status`, `save_run_status`, the
failure reasons in `process_set_part` and `part_done_cb`), `adblock-lean` (`do_start`).

Also fixed there (upstream bug): `processing_done_cb` glued the lists of failed job IDs together without a separator,
so '1' and '2' named job 12, whose good list was then dropped.

Also fixed (upstream bug): `process_set_part` kept `rogue_element` from an earlier download attempt, so after an
answer that was not a list (a web page) a good answer on the retry still counted as failed
(`tests/test-list-retry.sh`).

## Installer commands in the sysupgrade keep-file

`adblock-lean-plus-update`, `adblock-lean-plus-uninstall` and the installer's two notes (that it added the DoH
proxies, and which time server exceptions it added) are listed in `/lib/upgrade/keep.d/adblock-lean`, so they survive
a firmware upgrade.

## First start with a managed persistent blockset

A missing persistent blockset file at `start` in `managed` mode is normal (first start, after `sysupgrade`) and is
logged as information, not as an error.

## Install, update, upstream sync

See the README of the repository: `install.sh` installs and upgrades; `tools/sync-upstream.sh` pulls upstream
`next-version` into this subtree. Re-run `tools/ci.sh` and test on a router after every sync; drop a
change once upstream has an equivalent.

## Known upstream-relevant finding

Raw lists may contain `*.domain` entries (`val_entry_regex` accepts them). With a large blockset, such wildcard
`local=` entries make dnsmasq 2.93 noticeably slower for every uncached query (see the table above). Worth reporting upstream.
