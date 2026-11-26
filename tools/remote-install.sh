#!/bin/sh
# Router side of install.sh (BusyBox ash). Arguments: KEY=VALUE pairs from install.sh.
# install.sh copies the files to /tmp/adblock-lean-plus-install and runs this script from there.
set -u
GUI=0 DOH=0 DOH_GUI=0 INSTANCE='' PRESET='' LISTS='' PERSIST=0 START=0 ENABLE=0 UPGRADE=0 DRY=0
for kv in "$@"; do
	case "$kv" in
		GUI=[01]|DOH=[01]|DOH_GUI=[01]|PERSIST=[01]|START=[01]|ENABLE=[01]|UPGRADE=[01]|DRY=[01]|LISTS=|LISTS=adguard) eval "$kv" ;;
		PRESET=|PRESET=mini|PRESET=small|PRESET=medium|PRESET=large|PRESET=huge) eval "$kv" ;;
		INSTANCE=*) INSTANCE=${kv#INSTANCE=}; case "$INSTANCE" in *[!A-Za-z0-9_]*) echo "bad instance name"; exit 1 ;; esac ;;
		*) echo "unexpected argument: $kv"; exit 1 ;;
	esac
done
STAGE=$(cd "$(dirname "$0")/.." && pwd)
CFG=/etc/adblock-lean
SVC=/etc/init.d/adblock-lean
AG=https://adguardteam.github.io/HostlistsRegistry/assets
say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
# only ever remove the staging directory install.sh created
cleanup() { [ "$STAGE" = /tmp/adblock-lean-plus-install ] && rm -rf "$STAGE"; }
die() { printf '\nERROR: %s\n' "$*"; cleanup; exit 1; }
run() { if [ "$DRY" = 1 ]; then say "  would run: $*"; else "$@"; fi; }

# macOS metadata files must never reach the system directories
find "$STAGE" -name '._*' -exec rm -f {} + 2>/dev/null

step "Checking the router"
[ -f /etc/openwrt_release ] || die "this is not OpenWrt"
. /etc/openwrt_release
say "  ${DISTRIB_DESCRIPTION:-OpenWrt} (${DISTRIB_ARCH:-?})"
command -v dnsmasq >/dev/null || die "dnsmasq is not installed"
v=$(dnsmasq --version 2>/dev/null | sed -n '1s/.*version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
set -- $v
{ [ "${1:-0}" -gt 2 ] || { [ "${1:-0}" -eq 2 ] && [ "${2:-0}" -ge 86 ]; }; } || die "dnsmasq ${1:-?}.${2:-?} is too old (need 2.86+)"
say "  dnsmasq $1.$2"
if command -v apk >/dev/null; then PKG=apk; elif command -v opkg >/dev/null; then PKG=opkg; else die "no apk or opkg"; fi
say "  package manager: $PKG"

# preset: as adblock-lean chooses it (highest preset whose RAM, x800 KB, the router has)
mem_kb=$(awk '/^MemTotal/ { print $2 }' /proc/meminfo)
if [ -z "$PRESET" ]; then
	PRESET=mini
	for p in small:128 medium:256 large:512 huge:1024; do
		[ "$mem_kb" -ge $(( ${p#*:} * 800 )) ] && PRESET=${p%:*}
	done
fi
say "  RAM: $((mem_kb / 1024)) MB -> preset '$PRESET'"

need_kb=6000; [ "$PERSIST" = 1 ] && need_kb=$((need_kb + 15000))
free_kb=$(df -Pk /overlay 2>/dev/null | awk 'END { print $4 }')
case "$free_kb" in ''|*[!0-9]*) die "can not read the free space on /overlay" ;; esac
[ "$free_kb" -ge "$need_kb" ] || die "not enough space on /overlay: $free_kb KB free, need $need_kb KB"
say "  /overlay free: $free_kb KB"

# dnsmasq instance
instances=$(uci -q -X show dhcp | sed -n 's/^dhcp\.\([A-Za-z0-9_]*\)=dnsmasq$/\1/p')
if [ -z "$INSTANCE" ]; then
	n=$(printf '%s\n' "$instances" | grep -c .)
	[ "$n" = 1 ] || die "found $n dnsmasq instances ($(echo $instances)): choose one with --instance"
	INSTANCE=$instances
fi
printf '%s\n' "$instances" | grep -qx "$INSTANCE" || die "no dnsmasq instance '$INSTANCE' (have: $(echo $instances))"
confdir=$(sed -n 's/^conf-dir=\([^,]*\).*/\1/p' "/var/etc/dnsmasq.conf.$INSTANCE" 2>/dev/null | head -n1)
[ -n "$confdir" ] || confdir=$(uci -q get "dhcp.$INSTANCE.confdir")
[ -n "$confdir" ] || die "can not find the conf-dir of dnsmasq instance '$INSTANCE' (is it running?)"
say "  dnsmasq instance: $INSTANCE, conf-dir: $confdir, port: $(uci -q get "dhcp.$INSTANCE.port" || echo 53)"
{ [ "$GUI" = 1 ] || [ "$DOH_GUI" = 1 ]; } && { [ -d /www/luci-static ] || die "--gui/--doh-gui: LuCI is not installed"; }

if [ -e "$SVC" ] || [ -d /usr/lib/adblock-lean ]; then
	if [ "$UPGRADE" = 1 ]; then
		grep -q '^ABL_UPD_CHANNEL=local-fork' "$SVC" 2>/dev/null ||
			die "the installed adblock-lean is not adblock-lean-plus; uninstall it first (/etc/init.d/adblock-lean uninstall)"
		say "  existing adblock-lean-plus: scripts will be replaced, configs kept"
	else
		die "adblock-lean is already installed: use --upgrade to replace adblock-lean-plus scripts, or uninstall it first"
	fi
fi

if [ "$DOH" = 1 ]; then
	step "DoH proxy (https-dns-proxy)"
	if [ -f /etc/config/https-dns-proxy ]; then
		# an existing config must not let the package rewrite dnsmasq or the firewall
		[ "$(uci -q get https-dns-proxy.config.dnsmasq_config_update)" = '-' ] &&
		[ "$(uci -q get https-dns-proxy.config.force_dns)" = 0 ] ||
			die "/etc/config/https-dns-proxy exists and lets https-dns-proxy rewrite dnsmasq or the firewall (dnsmasq_config_update / force_dns). Remove it or set dnsmasq_config_update '-' and force_dns '0' (see config/https-dns-proxy), then run again"
		ports=$(uci -q show https-dns-proxy | sed -n "s/.*listen_port='\{0,1\}\([0-9]*\).*/\1/p" | tr '\n' ' ')
		say "  /etc/config/https-dns-proxy exists and is safe: kept (listen ports: $ports)"
	else
		run cp "$STAGE/config/https-dns-proxy" /etc/config/https-dns-proxy || die "can not write /etc/config/https-dns-proxy"
		say "  config written first, so the package leaves dnsmasq and the firewall alone"
	fi
	pkgs=https-dns-proxy
	[ "$DOH_GUI" = 1 ] && pkgs="$pkgs luci-app-https-dns-proxy"
	if [ "$PKG" = apk ]; then
		run apk update || die "apk update failed"
		run apk add $pkgs || die "apk add $pkgs failed"
	else
		run opkg update || die "opkg update failed"
		run opkg install $pkgs || die "opkg install $pkgs failed"
	fi
	[ "$DRY" = 1 ] || { sleep 3; netstat -lnu 2>/dev/null | grep -E '127\.0\.0\.1:50[0-9][0-9] ' | sed 's/^/  listening: /'; }
fi

if [ "$DRY" = 1 ]; then
	say "
Dry run: nothing was changed. Without --dry-run the steps above run, then the scripts, the configs
(preset '$PRESET'${LISTS:+ + AdGuard lists}) and, with --gui, the LuCI pages are installed."
	cleanup; exit 0
fi

step "adblock-lean-plus scripts"
cp "$STAGE/adblock-lean/adblock-lean" "$SVC" && chmod 755 "$SVC" || die "can not write $SVC"
mkdir -p /usr/lib/adblock-lean "$CFG" || die "can not create directories"
for f in "$STAGE"/adblock-lean/usr/lib/adblock-lean/*.sh; do
	cp "$f" /usr/lib/adblock-lean/ && chmod 644 "/usr/lib/adblock-lean/${f##*/}" || die "can not write /usr/lib/adblock-lean"
done
cp "$STAGE/adblock-lean/etc/adblock-lean/99-abl-hotplug.sh" "$CFG/" || die "can not write $CFG"
md5sum "$SVC" /usr/lib/adblock-lean/abl-lib.sh /usr/lib/adblock-lean/abl-process.sh \
	/usr/lib/adblock-lean/abl-manage.sh /usr/lib/adblock-lean/abl-scheduler.sh > "$CFG/abl-reg.md5" || die "can not register files"
say "  installed $(sed -n 's/^ABL_VERSION=//p' "$SVC")"

step "Configuration"
gen_cfg() { sh -c ". $SVC; detect_main_utils; . /usr/lib/adblock-lean/abl-lib.sh; print_def_cfg $*"; }
if [ -f "$CFG/global.conf" ]; then
	say "  $CFG/global.conf exists: kept"
else
	gen_cfg global > "$CFG/global.conf.new" && [ -s "$CFG/global.conf.new" ] || die "can not generate global.conf"
	sed -i 's|^upd_schedule=.*|upd_schedule="0 5 * * *"|' "$CFG/global.conf.new"
	mv "$CFG/global.conf.new" "$CFG/global.conf"
	say "  global.conf: lists update daily at 05:00 (+ random delay) once enabled"
fi
set -- "$CFG"/blockset-*.conf
if [ -f "$1" ]; then
	say "  blockset config exists (${1##*/}): kept"
else
	B="$CFG/blockset-01.conf"
	gen_cfg bl -i 01 -p "$PRESET" -n "$INSTANCE" -c "$confdir" > "$B.new" && [ -s "$B.new" ] || die "can not generate the blockset config"
	if [ "$LISTS" = adguard ]; then
		# room for ~200k more entries
		sed -i "s|^adguard_block_lists=.*|adguard_block_lists=\"$AG/filter_1.txt $AG/filter_59.txt\"|" "$B.new"
		awk -F'"' '/^max_blockset_size_KB=/ { sub(/="[0-9]+"/, "=\"" $2 + 10000 "\"") } { print }' "$B.new" > "$B.tmp" && mv "$B.tmp" "$B.new"
	fi
	if [ "$PERSIST" = 1 ]; then
		sed -i "s|^persist_blockset_mode=.*|persist_blockset_mode=\"managed\"|; s|^persist_blockset_dir=.*|persist_blockset_dir=\"$CFG/persist\"|" "$B.new"
		mkdir -p "$CFG/persist"
	fi
	mv "$B.new" "$B"
	say "  blockset-01.conf: instance $INSTANCE, preset '$PRESET': $(sed -n 's/^raw_block_lists="\(.*\)"/\1/p' "$B")${LISTS:+ + AdGuard DNS filter, Popup Hosts}"
	[ "$PERSIST" = 1 ] && say "  the blockset is kept in $CFG/persist (loaded before dnsmasq starts after a reboot)"
fi
"$SVC" create_addnmounts >/dev/null 2>&1 && say "  dnsmasq addnmount entries checked" || say "  WARNING: '/etc/init.d/adblock-lean create_addnmounts' failed; run it by hand"

if [ "$GUI" = 1 ]; then
	step "LuCI pages"
	# file by file with plain cp: never copy owners/modes onto existing system directories
	( cd "$STAGE/luci-app/luci-app-adblock-lean/root" && find . -type f ) | while read -r f; do
		mkdir -p "/${f%/*}" && cp "$STAGE/luci-app/luci-app-adblock-lean/root/$f" "/$f" || exit 1
	done || die "can not install the LuCI files"
	chmod 755 /usr/libexec/rpcd/luci.adblock-lean
	chmod 644 /usr/share/rpcd/acl.d/luci-app-adblock-lean.json /usr/share/luci/menu.d/luci-app-adblock-lean.json
	mkdir -p /www/luci-static/resources/view/adblock-lean &&
	cp "$STAGE"/luci-app/luci-app-adblock-lean/htdocs/luci-static/resources/view/adblock-lean/*.js /www/luci-static/resources/view/adblock-lean/ &&
	chmod 644 /www/luci-static/resources/view/adblock-lean/*.js || die "can not install the LuCI views"
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache
	/etc/init.d/rpcd reload
	say "  Services -> Adblock-lean (log out of LuCI and back in)"
fi

if [ "$START" = 1 ]; then
	step "Downloading the lists and loading them into dnsmasq (1-3 minutes)"
	if "$SVC" start >/dev/null 2>&1; then say "  started"; else say "  WARNING: start failed, see: logread -e adblock-lean"; fi
fi
if [ "$ENABLE" = 1 ]; then
	"$SVC" enable >/dev/null 2>&1 && say "  enabled at boot" || say "  WARNING: enable failed"
fi
cleanup

step "Next steps"
port=$(uci -q get "dhcp.$INSTANCE.port"); port=${port:-53}
[ "$START" = 1 ] || say "  start:            /etc/init.d/adblock-lean start"
[ "$ENABLE" = 1 ] || say "  start at boot:    /etc/init.d/adblock-lean enable"
if [ "$DOH" = 1 ]; then
	say "  use the DoH proxies as dnsmasq's only upstreams (not done by the installer):"
	say "    uci set dhcp.$INSTANCE.noresolv='1'"
	say "    uci -q del dhcp.$INSTANCE.server"
	for pt in $(uci -q show https-dns-proxy | sed -n "s/.*listen_port='\{0,1\}\([0-9]*\).*/\1/p"); do
		say "    uci add_list dhcp.$INSTANCE.server='127.0.0.1#$pt'"
	done
	say "    uci commit dhcp && /etc/init.d/dnsmasq restart"
	say "    (re-add any server=/domain/address entries you had, e.g. for NTP or local zones)"
fi
[ "$port" = 53 ] || say "  dnsmasq '$INSTANCE' listens on port $port: clients only see the filter once it answers on port 53 (README: Switching from AdGuard Home)"
