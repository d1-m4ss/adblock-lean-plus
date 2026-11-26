#!/bin/sh
# Router side of install.sh (BusyBox ash). Arguments: KEY=VALUE pairs from install.sh; an empty value means
# "not given on the command line": asked in a terminal, otherwise the default.
# install.sh runs it from the unpacked repository (on the router), or copies the files to
# /tmp/adblock-lean-plus-install over SSH and runs it from there.
set -u
GUI='' DOH='' DOH_GUI='' USE_DOH='' UTILS='' PERSIST='' START='' ENABLE='' INSTANCE='' PRESET='' LISTS=''
UPGRADE=0 DRY=0 YES=0
for kv in "$@"; do
	case "$kv" in
		GUI=|GUI=[01]|DOH=|DOH=[01]|DOH_GUI=|DOH_GUI=[01]|USE_DOH=|USE_DOH=[01]|UTILS=|UTILS=[01]) eval "$kv" ;;
		PERSIST=|PERSIST=[01]|START=|START=[01]|ENABLE=|ENABLE=[01]|UPGRADE=[01]|DRY=[01]|YES=[01]|LISTS=|LISTS=adguard) eval "$kv" ;;
		PRESET=|PRESET=mini|PRESET=small|PRESET=medium|PRESET=large|PRESET=huge) eval "$kv" ;;
		INSTANCE=*) INSTANCE=${kv#INSTANCE=}; case "$INSTANCE" in *[!A-Za-z0-9_]*) echo "bad instance name"; exit 1 ;; esac ;;
		*) echo "unexpected argument: $kv"; exit 1 ;;
	esac
done
STAGE=$(cd "$(dirname "$0")/.." && pwd)
CFG=/etc/adblock-lean
SVC=/etc/init.d/adblock-lean
DOH_CFG=/etc/config/https-dns-proxy
DHCP_BAK=/tmp/adblock-lean-plus-dhcp.bak
AG=https://adguardteam.github.io/HostlistsRegistry/assets
NTP_DNS='1.1.1.1 1.0.0.1'
INTERACTIVE=0; [ "$YES" = 0 ] && [ -t 0 ] && INTERACTIVE=1
say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
# only ever remove the staging directory install.sh created
cleanup() { [ "$STAGE" = /tmp/adblock-lean-plus-install ] && rm -rf "$STAGE"; }
die() { printf '\nERROR: %s\n' "$*"; cleanup; exit 1; }
yn() { [ "$1" = 1 ] && echo yes || echo no; }

# ask VAR RECOMMENDED UNATTENDED QUESTION: sets VAR to 0|1 unless the command line already did.
# In a terminal the question is asked with RECOMMENDED as default; with --yes RECOMMENDED is taken;
# otherwise (no terminal) UNATTENDED.
ask() {
	eval "_a=\$$1"
	[ -n "$_a" ] && return 0
	if [ "$INTERACTIVE" = 1 ]; then
		_h='[y/N]'; [ "$2" = 1 ] && _h='[Y/n]'
		while :; do
			printf '  %s %s ' "$4" "$_h"
			read -r _a || die "no answer"
			case "$_a" in
				'') _a=$2 ;;
				y|Y|yes|Yes) _a=1 ;;
				n|N|no|No) _a=0 ;;
				*) say "  please answer y or n"; continue ;;
			esac
			break
		done
	elif [ "$YES" = 1 ]; then
		_a=$2
	else
		_a=$3
		eval "UNASKED_$1=1"
	fi
	eval "$1=\$_a"
}

pkg_installed() {
	if [ "$PKG" = apk ]; then apk info -e "$1" >/dev/null 2>&1
	else opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "; fi
}
pkg_update() { if [ "$PKG" = apk ]; then apk update </dev/null; else opkg update </dev/null; fi; }
pkg_add() { if [ "$PKG" = apk ]; then apk add "$@" </dev/null; else opkg install "$@" </dev/null; fi; }

# listen ports of https-dns-proxy, from the installed config or the one about to be installed
doh_ports() {
	_f=$DOH_CFG; [ -f "$_f" ] || _f=$STAGE/config/https-dns-proxy
	sed -n "s/^[[:space:]]*option[[:space:]]*listen_port[[:space:]]*['\"]\{0,1\}\([0-9]*\).*/\1/p" "$_f"
}
# true if the https-dns-proxy config never touches dnsmasq or the firewall
doh_safe() {
	[ "$(uci -q get https-dns-proxy.config.dnsmasq_config_update)" = '-' ] &&
	[ "$(uci -q get https-dns-proxy.config.force_dns)" = 0 ]
}
# dnsmasq upstreams for all domains (per-domain entries /name/ip are not listed)
plain_upstreams() {
	for _s in $(uci -q get "dhcp.$INSTANCE.server"); do
		case "$_s" in
			'/#/'*) printf '%s ' "$_s" ;;
			/*) ;;
			*) printf '%s ' "$_s" ;;
		esac
	done
}
# dnsmasq forwards only to proxies on this router
local_only() {
	[ "$(uci -q get "dhcp.$INSTANCE.noresolv")" = 1 ] || return 1
	_u=$(plain_upstreams); [ -n "$_u" ] || return 1
	for _s in $_u; do case "$_s" in '127.0.0.1#'*|'::1#'*) ;; *) return 1 ;; esac; done
}
# dnsmasq forwards only to the https-dns-proxy ports
uses_doh() {
	local_only || return 1
	_p=" $(doh_ports | tr '\n' ' ') "
	for _s in $(plain_upstreams); do case "$_p" in *" ${_s#*#} "*) ;; *) return 1 ;; esac; done
}
# NTP server names that still have no per-domain upstream. Without one, a router whose clock is far off can not
# recover: DoH needs a correct time (TLS certificates), and setting the time needs DNS.
ntp_missing() {
	_local=$(uci -q get "dhcp.$INSTANCE.domain")
	for _h in $(uci -q get system.ntp.server); do
		case "$_h" in *:*) continue ;; *[!0-9.]*) ;; *) continue ;; esac	# IP addresses need no DNS
		case "$_h" in
			pool.ntp.org|*.pool.ntp.org) _h=pool.ntp.org ;;
			*.lan|*.local|*.home.arpa) continue ;;
			*.*) ;;
			*) continue ;;
		esac
		[ -n "$_local" ] && case "$_h" in *".$_local") continue ;; esac
		_found=0
		for _s in $(uci -q get "dhcp.$INSTANCE.server"); do
			case "$_s" in /*"/$_h/"*|"/$_h/"*) _found=1 ;; esac
		done
		[ "$_found" = 1 ] || say "$_h"
	done | sort -u
}
resolves() { # port [name] [tries]: wait until the DNS server on 127.0.0.1:port resolves the name
	_n=0
	while [ "$_n" -lt "${3:-10}" ]; do
		nslookup -type=a -port="$1" "${2:-openwrt.org}" 127.0.0.1 >/dev/null 2>&1 && return 0
		sleep 1; _n=$((_n + 1))
	done
	return 1
}
restore_dhcp() {
	uci -q revert dhcp
	cp "$DHCP_BAK" /etc/config/dhcp && /etc/init.d/dnsmasq restart >/dev/null 2>&1
	say "  previous DNS settings restored"
}
# change_dns switch|ntp: edit the dnsmasq upstreams, restart dnsmasq, check that it resolves, else undo.
# Returns 0: done; 2: done, except time server exceptions that do not work on this network; 1: failed, undone.
change_dns() {
	[ -z "$(uci -q changes dhcp)" ] || {
		say "  WARNING: /etc/config/dhcp has uncommitted changes ('uci changes dhcp'): DNS settings not changed"; return 1; }
	if [ "$1" = switch ]; then
		_ok='' _silent=''
		for _pt in $(doh_ports); do
			if resolves "$_pt"; then _ok="$_ok $_pt"; else _silent="$_silent $_pt"; fi
		done
		[ -n "$_ok" ] || { say "  WARNING: no DoH proxy answers: dnsmasq's upstreams not changed (logread -e https-dns-proxy)"; return 1; }
		say "  DoH proxies answering on ports:$_ok"
		[ -z "$_silent" ] || say "  WARNING: no answer on ports:$_silent (kept in the list: dnsmasq skips a proxy while it fails)"
	fi
	_port=$(uci -q get "dhcp.$INSTANCE.port"); _port=${_port:-53}
	cp /etc/config/dhcp "$DHCP_BAK" || { say "  WARNING: can not back up /etc/config/dhcp"; return 1; }
	# a lost SSH session must not end the script between the change and the rollback: no SIGPIPE on output
	trap '' PIPE
	trap 'restore_dhcp; cleanup; exit 1' HUP INT TERM
	set -f
	_rv=0 _added=''
	if [ "$1" = switch ]; then
		for _s in $(plain_upstreams); do uci del_list "dhcp.$INSTANCE.server=$_s" || _rv=1; done
		for _pt in $(doh_ports); do uci add_list "dhcp.$INSTANCE.server=127.0.0.1#$_pt" || _rv=1; done
		uci set "dhcp.$INSTANCE.noresolv=1" || _rv=1
	fi
	for _d in $(ntp_missing); do
		for _ip in $NTP_DNS; do uci add_list "dhcp.$INSTANCE.server=/$_d/$_ip" || _rv=1; done
		_added="$_added $_d"
		say "  NTP: '$_d' is resolved over plain DNS ($NTP_DNS), so the clock can always be set"
	done
	set +f
	[ "$_rv" = 0 ] && uci commit dhcp && /etc/init.d/dnsmasq restart >/dev/null 2>&1 &&
		resolves "$_port" openwrt.org 20 || _rv=1
	if [ "$_rv" != 0 ]; then
		say "  WARNING: DNS does not work with the new settings"
		restore_dhcp
	else
		[ "$1" = switch ] && say "  dnsmasq '$INSTANCE' now forwards to the DoH proxies only"
		# the exceptions are only worth keeping if plain DNS gets through on this network
		_bad=''
		for _d in $_added; do resolves "$_port" "$_d" 5 || _bad="$_bad $_d"; done
		if [ -n "$_bad" ]; then
			for _d in $_bad; do
				for _ip in $NTP_DNS; do uci del_list "dhcp.$INSTANCE.server=/$_d/$_ip"; done
				say "  WARNING: '$_d' does not resolve over plain DNS (blocked on this network?): exception removed"
			done
			if uci commit dhcp && /etc/init.d/dnsmasq restart >/dev/null 2>&1 && resolves "$_port" openwrt.org 20; then
				_rv=2
			else
				restore_dhcp
				_rv=1
			fi
		fi
		rm -f "$DHCP_BAK"
	fi
	trap - HUP INT TERM PIPE
	return "$_rv"
}

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
# the installer commits /etc/config/dhcp; it must not commit someone's half-made changes along with its own
[ -z "$(uci -q changes dhcp)" ] || die "/etc/config/dhcp has uncommitted changes: 'uci commit dhcp' or 'uci revert dhcp' first"
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

# dnsmasq instance
instances=$(uci -q -X show dhcp | sed -n 's/^dhcp\.\([A-Za-z0-9_]*\)=dnsmasq$/\1/p')
if [ -z "$INSTANCE" ]; then
	n=$(printf '%s\n' "$instances" | grep -c .)
	if [ "$n" = 1 ]; then
		INSTANCE=$instances
	elif [ "$INTERACTIVE" = 1 ] && [ "$n" -gt 1 ]; then
		printf '  dnsmasq instances: %s\n  Which one should be filtered? ' "$(echo $instances)"
		read -r INSTANCE || die "no answer"
		case "$INSTANCE" in ''|*[!A-Za-z0-9_]*) die "bad instance name" ;; esac
	else
		die "found $n dnsmasq instances ($(echo $instances)): choose one with --instance"
	fi
fi
printf '%s\n' "$instances" | grep -qxF -e "$INSTANCE" || die "no dnsmasq instance '$INSTANCE' (have: $(echo $instances))"
port=$(uci -q get "dhcp.$INSTANCE.port"); port=${port:-53}
say "  dnsmasq instance: $INSTANCE, port: $port"

installed=0
if [ -e "$SVC" ] || [ -d /usr/lib/adblock-lean ]; then
	installed=1
	grep -q '^ABL_UPD_CHANNEL=local-fork' "$SVC" 2>/dev/null ||
		die "the installed adblock-lean is not adblock-lean-plus; uninstall it first (/etc/init.d/adblock-lean uninstall)"
	if [ "$UPGRADE" = 0 ]; then
		[ "$INTERACTIVE" = 1 ] || die "adblock-lean-plus is already installed: add --upgrade to replace its scripts"
		UPGRADE=''
		ask UPGRADE 1 0 "adblock-lean-plus is already installed. Upgrade it (settings are kept)?"
		[ "$UPGRADE" = 1 ] || die "nothing to do"
	fi
	say "  existing adblock-lean-plus: scripts will be replaced, configs kept"
fi
have_cfg=0
set -- "$CFG"/blockset-*.conf
[ -f "$1" ] && have_cfg=1
confdir=''
if [ "$have_cfg" = 0 ]; then
	confdir=$(sed -n 's/^conf-dir=\([^,]*\).*/\1/p' "/var/etc/dnsmasq.conf.$INSTANCE" 2>/dev/null | head -n1)
	[ -n "$confdir" ] || confdir=$(uci -q get "dhcp.$INSTANCE.confdir")
	[ -n "$confdir" ] || die "can not find the conf-dir of dnsmasq instance '$INSTANCE' (is it running?)"
fi
enabled=0; [ "$installed" = 1 ] && "$SVC" enabled 2>/dev/null && enabled=1

[ "$INTERACTIVE" = 1 ] && step "Questions (Enter takes the answer in capitals)"

# web pages
luci=0; [ -d /www/luci-static ] && luci=1
if [ "$luci" = 1 ]; then
	gui_present=0; [ -f /usr/share/luci/menu.d/luci-app-adblock-lean.json ] && gui_present=1
	verb=Install; [ "$gui_present" = 0 ] || verb=Update
	ask GUI 1 "$gui_present" "$verb the web pages (LuCI: Services -> Adblock-lean-plus)?"
else
	[ "$GUI" = 1 ] || [ "$DOH_GUI" = 1 ] && die "--gui/--doh-gui: LuCI is not installed"
	GUI=0 DOH_GUI=0
fi

# encrypted DNS
others=''
for s in adguardhome stubby dnscrypt-proxy smartdns unbound mosdns; do
	[ -x "/etc/init.d/$s" ] && "/etc/init.d/$s" enabled 2>/dev/null && others="$others $s"
done
pidof AdGuardHome >/dev/null 2>&1 && case "$others" in *adguardhome*) ;; *) others="$others adguardhome" ;; esac
doh_present=0; [ -x /etc/init.d/https-dns-proxy ] && doh_present=1
say "  Encrypted DNS (DoH):"
upstreams=$(plain_upstreams)
if [ -n "$upstreams" ]; then say "    dnsmasq forwards to: $upstreams"
elif [ "$(uci -q get "dhcp.$INSTANCE.noresolv")" != 1 ]; then say "    dnsmasq uses the DNS servers of the internet connection (not encrypted)"; fi
[ -z "$others" ] || say "    another DNS resolver is set up:$others"
if [ "$doh_present" = 1 ]; then
	say "    https-dns-proxy is already installed: its settings are kept"
	[ -n "$DOH" ] || DOH=0
	[ "$DOH_GUI" = 1 ] && DOH=1
else
	rec=1; [ -z "$others" ] || rec=0
	ask DOH "$rec" 0 "Install DoH proxies (Cloudflare, AdGuard unfiltered, Quad9)?"
fi
if [ "$DOH" = 1 ]; then
	[ ! -f "$DOH_CFG" ] || doh_safe ||
		die "$DOH_CFG exists and lets https-dns-proxy rewrite dnsmasq or the firewall (dnsmasq_config_update / force_dns). Remove it or set dnsmasq_config_update '-' and force_dns '0' (see config/https-dns-proxy), then run again"
	if [ "$luci" = 1 ] && ! pkg_installed luci-app-https-dns-proxy; then
		ask DOH_GUI "$GUI" 0 "Also install the LuCI page for the DoH servers?"
	fi
fi
[ -n "$DOH_GUI" ] && [ "$DOH" = 1 ] || DOH_GUI=0

NTPFIX=''
if [ "$DOH" = 1 ] || [ "$doh_present" = 1 ]; then
	if [ -f "$DOH_CFG" ] && ! doh_safe; then
		say "    https-dns-proxy configures dnsmasq itself: upstreams are left to it"
		USE_DOH=0
	elif uses_doh; then
		say "    dnsmasq already uses the DoH proxies"
		[ "$USE_DOH" = 1 ] && [ -n "$(ntp_missing)" ] && NTPFIX=1
		USE_DOH=0
	else
		# a resolver or proxies that were here before this run: the suggestion is to leave DNS alone
		rec=1; { [ -z "$others" ] && [ "$doh_present" = 0 ]; } || rec=0
		ask USE_DOH "$rec" "$DOH" "Make dnsmasq use the DoH proxies now (replaces its other upstreams, keeps per-domain entries)?"
	fi
else
	[ "$USE_DOH" != 1 ] || die "--use-doh needs https-dns-proxy: add --doh"
	USE_DOH=0
fi
if [ "$USE_DOH" = 0 ] && local_only && [ -n "$(ntp_missing)" ]; then
	say "    the time server names ($(echo $(ntp_missing))) are resolved only through the local proxies: after a long"
	say "    power cut the router may fail to set its clock, and encrypted DNS then fails too"
	ask NTPFIX 1 0 "Resolve the time server names over plain DNS?"
fi
[ "$NTPFIX" = 1 ] || NTPFIX=0

# blockset (only when there is no config yet)
if [ "$have_cfg" = 0 ]; then
	ask PERSIST 0 0 "Keep the blocklist on flash? Filtering works right after boot, but ~10 MB are rewritten on every update."
	if [ -z "$LISTS" ]; then
		ADGUARD=''
		ask ADGUARD 0 0 "Add AdGuard DNS filter and AdGuard Popup Hosts to the HaGeZi lists of preset '$PRESET'?"
		[ "$ADGUARD" = 1 ] && LISTS=adguard
	fi
else
	{ [ "$PERSIST" = 1 ] || [ -n "$LISTS" ]; } && say "  blocklist settings exist and are kept: --persist/--lists ignored"
	PERSIST=0 LISTS=''
fi

missing_utils=''
for p in gawk sed coreutils-sort; do pkg_installed "$p" || missing_utils="$missing_utils $p"; done
if [ -n "$missing_utils" ]; then
	ask UTILS 1 0 "Install$missing_utils (faster list processing)?"
else
	UTILS=0
fi
ask START 1 0 "Download the lists and start blocking now?"
if [ "$enabled" = 1 ]; then
	# nothing to ask: the installer never disables the service
	[ "$ENABLE" = 0 ] || ENABLE=1
else
	ask ENABLE 1 0 "Start automatically at boot and update the lists daily?"
fi

step "Plan: what will be done now"
# a part that is already in place says so; "skipped" is a part that is absent and stays so
row() { printf '  %-20s %s\n' "$1:" "$2"; }
row "adblock-lean-plus" "$([ "$installed" = 1 ] && echo 'upgrade, settings kept' || echo install)"
if [ "$GUI" = 1 ]; then t=install; [ "${gui_present:-0}" = 0 ] || t=update
elif [ "${gui_present:-0}" = 1 ]; then t='installed, not updated'
else t=skipped; fi
row "web pages" "$t"
if [ "$doh_present" = 1 ]; then t='already installed, kept'; [ "$DOH_GUI" != 1 ] || t="$t; add its LuCI page"
elif [ "$DOH" = 1 ]; then t=install; [ "$DOH_GUI" != 1 ] || t='install, with the LuCI page'
else t=skipped; fi
row "DoH proxies" "$t"
if [ "$USE_DOH" = 1 ]; then t='switch to the DoH proxies'
elif { [ "$DOH" = 1 ] || [ "$doh_present" = 1 ]; } && uses_doh; then t='already the DoH proxies'
else t=unchanged; fi
row "dnsmasq upstreams" "$t"
[ "$NTPFIX" != 1 ] || row "time server names" "add a plain-DNS exception"
[ "$have_cfg" = 1 ] || row "blocklists" "preset '$PRESET'${LISTS:+ + AdGuard lists}, kept on flash: $(yn "$PERSIST")"
if [ -z "$missing_utils" ]; then t='already installed'
elif [ "$UTILS" = 1 ]; then t="install $(echo $missing_utils)"
else t=skipped; fi
row "speed-up tools" "$t"
t=$(yn "$START"); [ "${UNASKED_START:-0}" != 1 ] || t='not now (not asked)'
row "start now" "$t"
if [ "$enabled" = 1 ]; then t='already enabled'; else t=$(yn "$ENABLE"); [ "${UNASKED_ENABLE:-0}" != 1 ] || t='not now (not asked)'; fi
row "start at boot" "$t"

need_kb=6000
[ "$PERSIST" = 1 ] && need_kb=$((need_kb + 15000))
[ "$UTILS" = 1 ] && need_kb=$((need_kb + 3000))
free_kb=$(df -Pk /overlay 2>/dev/null | awk 'END { print $4 }')
case "$free_kb" in ''|*[!0-9]*) die "can not read the free space on /overlay" ;; esac
[ "$free_kb" -ge "$need_kb" ] || die "not enough space on /overlay: $free_kb KB free, need $need_kb KB"

if [ "$DRY" = 1 ]; then
	say "
Dry run: nothing was changed."
	cleanup; exit 0
fi
if [ "$INTERACTIVE" = 1 ]; then
	CONFIRM=''
	ask CONFIRM 1 1 "Proceed?"
	[ "$CONFIRM" = 1 ] || { say "Cancelled, nothing was changed."; cleanup; exit 0; }
fi

if [ "$DOH" = 1 ] || [ "$UTILS" = 1 ]; then
	step "Packages"
	updated=1; pkg_update || updated=0
fi
if [ "$DOH" = 1 ]; then
	[ "$updated" = 1 ] || die "$PKG update failed"
	new_cfg=0
	if [ ! -f "$DOH_CFG" ]; then
		cp "$STAGE/config/https-dns-proxy" "$DOH_CFG" || die "can not write $DOH_CFG"
		new_cfg=1
		say "  DoH settings written first, so the package leaves dnsmasq and the firewall alone"
	fi
	pkgs=https-dns-proxy
	[ "$DOH_GUI" = 1 ] && pkgs="$pkgs luci-app-https-dns-proxy"
	pkg_add $pkgs || die "installing $pkgs failed"
	# the package's own default config, saved next to ours, is not needed
	[ "$new_cfg" = 1 ] && rm -f "$DOH_CFG.apk-new" "$DOH_CFG-opkg"
	# so that the uninstaller knows the proxies are ours, even after their settings were edited
	[ "$doh_present" = 1 ] || { mkdir -p "$CFG" && : > "$CFG/doh-added-by-installer"; }
	/etc/init.d/https-dns-proxy enabled || /etc/init.d/https-dns-proxy enable
	/etc/init.d/https-dns-proxy running >/dev/null 2>&1 || /etc/init.d/https-dns-proxy start >/dev/null 2>&1
fi
if [ "$UTILS" = 1 ]; then
	{ [ "$updated" = 1 ] && pkg_add $missing_utils; } ||
		say "  WARNING: could not install$missing_utils; adblock-lean works without them, only slower"
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
# the update and uninstall commands; replaced with a rename, as the update command may be the one running
for c in get.sh:adblock-lean-plus-update uninstall.sh:adblock-lean-plus-uninstall; do
	t=/usr/sbin/${c#*:}
	cp "$STAGE/${c%:*}" "$t.new" && chmod 755 "$t.new" && mv "$t.new" "$t" || die "can not install $t"
done
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
if [ "$have_cfg" = 1 ]; then
	say "  blocklist config exists: kept"
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
	[ "$PERSIST" = 1 ] && say "  the blocklist is kept in $CFG/persist (loaded before dnsmasq starts after a reboot)"
fi
# DO_DIALOGS=0: adblock-lean asks nothing, the answers were given above
DO_DIALOGS=0 "$SVC" create_addnmounts </dev/null >/dev/null 2>&1 && say "  dnsmasq addnmount entries checked" ||
	say "  WARNING: '/etc/init.d/adblock-lean create_addnmounts' failed; run it by hand"

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
	say "  installed"
fi

failed=''
if [ "$USE_DOH" = 1 ]; then
	step "DNS settings"
	change_dns switch
	[ $? != 1 ] || failed="$failed dns"
elif [ "$NTPFIX" = 1 ]; then
	step "DNS settings"
	change_dns ntp
	[ $? != 1 ] || failed="$failed time-servers"
fi

if [ "$START" = 1 ]; then
	step "Downloading the lists and loading them into dnsmasq (1-3 minutes)"
	if DO_DIALOGS=0 "$SVC" start; then
		say "  started"
	else
		say "  WARNING: start failed, see: logread -e adblock-lean"
		say "  (if the config needs changes, '/etc/init.d/adblock-lean start' in a terminal asks about them)"
		failed="$failed start"
	fi
fi
if [ "$ENABLE" = 1 ] && [ "$enabled" != 1 ]; then
	if DO_DIALOGS=0 "$SVC" enable; then say "  enabled at boot"; else say "  WARNING: enable failed"; failed="$failed enable"; fi
fi
cleanup

step "Done"
[ -z "$failed" ] || say "  some steps failed, see the warnings above:$failed"
[ "$GUI" = 1 ] && say "  web pages: Services -> Adblock-lean-plus (log out of LuCI and back in)"
# no advice about steps that were declined; only about failed ones and those nobody was asked about
[ "${UNASKED_START:-0}" = 1 ] && say "  to start blocking:    /etc/init.d/adblock-lean start"
[ "${UNASKED_ENABLE:-0}" = 1 ] && say "  to start at boot:     /etc/init.d/adblock-lean enable"
# --use-doh replaces dnsmasq's upstreams: advise it only for a switch that was wanted and failed, or where dnsmasq
# uses the DoH proxies already (then it only adds the time server exceptions)
case " $failed " in
	*' dns '*) say "  to try the DNS switch again, run the installer again with: --upgrade --use-doh" ;;
	*)
		case "${UNASKED_NTPFIX:-0} $failed " in
			1*|*' time-servers '*)
				if [ -x /etc/init.d/https-dns-proxy ] && uses_doh; then
					say "  to resolve the time server names over plain DNS, run the installer again with: --upgrade --use-doh"
				else
					say "  to resolve the time server names over plain DNS, run the installer again in a terminal (--upgrade)"
					say "  and answer yes to the question about the time servers"
				fi
		esac
esac
say "  to update:            adblock-lean-plus-update"
say "  to uninstall:         adblock-lean-plus-uninstall"
[ "$port" = 53 ] || say "  dnsmasq '$INSTANCE' listens on port $port: clients get filtering only once it answers on port 53 (README: If you already run AdGuard Home)"
