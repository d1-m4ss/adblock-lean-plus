#!/bin/sh
# adblock-lean-plus uninstaller. Runs on the router:
#
#   adblock-lean-plus-uninstall        (the installer puts it there)
#   sh uninstall.sh                    (from an unpacked archive of the repository)
#
# It looks at what is installed, asks, shows the plan and removes it. DNS is given other servers before the DoH
# proxies go; if DNS would stop working, nothing is removed.
#   -y, --yes          ask nothing: remove the blocker, its settings, the web pages and the DoH proxies
#                      the installer added
#   --keep-settings    keep /etc/adblock-lean (lists, schedule, local allow/block lists)
#   --keep-doh         keep the DoH proxies and dnsmasq's upstream servers
#   --remove-doh       remove https-dns-proxy even if the installer did not add it
#   --dry-run          show the plan; change nothing
# SPDX-License-Identifier: GPL-2.0-only
set -u

CFG=/etc/adblock-lean
SVC=/etc/init.d/adblock-lean
SELF=/usr/sbin/adblock-lean-plus-uninstall
UPDATE_CMD=/usr/sbin/adblock-lean-plus-update
DOH_CFG=/etc/config/https-dns-proxy
DOH_MARK=$CFG/doh-added-by-installer
DHCP_BAK=/tmp/adblock-lean-plus-dhcp.bak
VIEWS=/www/luci-static/resources/view/adblock-lean
RPCD=/usr/libexec/rpcd/luci.adblock-lean
NTP_DNS='1.1.1.1 1.0.0.1'
FALLBACK_DNS=1.1.1.1

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*"; exit 1; }
usage() { sed -n '2,/^# SPDX/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

YES=0 DRY=0 KEEP_SETTINGS='' REMOVE_DOH=''
while [ $# -gt 0 ]; do
	case "$1" in
		-y|--yes) YES=1 ;;
		--keep-settings) KEEP_SETTINGS=1 ;;
		--keep-doh) REMOVE_DOH=0 ;;
		--remove-doh) REMOVE_DOH=1 ;;
		--dry-run) DRY=1 ;;
		-h|--help) usage 0 ;;
		*) say "unknown option: $1"; usage 1 ;;
	esac
	shift
done
INTERACTIVE=0; [ "$YES" = 0 ] && [ -t 0 ] && INTERACTIVE=1

# ask VAR DEFAULT QUESTION: sets VAR to 0|1 unless an option already did; without a terminal takes DEFAULT
ask() {
	eval "_a=\$$1"
	[ -n "$_a" ] && return 0
	if [ "$INTERACTIVE" = 1 ]; then
		_h='[y/N]'; [ "$2" = 1 ] && _h='[Y/n]'
		while :; do
			printf '  %s %s ' "$3" "$_h"
			read -r _a || die "no answer, nothing was changed"
			case "$_a" in
				'') _a=$2 ;;
				y|Y|yes|Yes) _a=1 ;;
				n|N|no|No) _a=0 ;;
				*) say "  please answer y or n"; continue ;;
			esac
			break
		done
	else
		_a=$2
	fi
	eval "$1=\$_a"
}

if command -v apk >/dev/null; then PKG=apk; else PKG=opkg; fi
pkg_installed() {
	if [ "$PKG" = apk ]; then apk info -e "$1" >/dev/null 2>&1
	else opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "; fi
}
pkg_del() { if [ "$PKG" = apk ]; then apk del "$@" </dev/null; else opkg remove "$@" </dev/null; fi; }

instances() { uci -q -X show dhcp | sed -n 's/^dhcp\.\([A-Za-z0-9_]*\)=dnsmasq$/\1/p'; }
# listen ports of the installed https-dns-proxy (the installer's three if its config is gone)
doh_ports() {
	_p=$([ -f "$DOH_CFG" ] && sed -n "s/^[[:space:]]*option[[:space:]]*listen_port[[:space:]]*['\"]\{0,1\}\([0-9]*\).*/\1/p" "$DOH_CFG")
	echo ${_p:-5053 5054 5055}
}
is_proxy() { # server entry
	case "$1" in '127.0.0.1#'*) ;; *) return 1 ;; esac
	case " $(doh_ports) " in *" ${1#*#} "*) return 0 ;; esac
	return 1
}
uses_proxies() { # instance
	for _s in $(uci -q get "dhcp.$1.server"); do is_proxy "$_s" && return 0; done
	return 1
}
# the time server names the installer may have added plain-DNS exceptions for
ntp_domains() {
	for _h in $(uci -q get system.ntp.server); do
		case "$_h" in *:*) continue ;; *[!0-9.]*) ;; *) continue ;; esac
		case "$_h" in pool.ntp.org|*.pool.ntp.org) _h=pool.ntp.org ;; esac
		say "$_h"
	done | sort -u
}
resolves() { # port
	_n=0
	while [ "$_n" -lt 20 ]; do
		nslookup -type=a -port="$1" openwrt.org 127.0.0.1 >/dev/null 2>&1 && return 0
		sleep 1; _n=$((_n + 1))
	done
	return 1
}
restore_dhcp() {
	uci -q revert dhcp
	if cp "$DHCP_BAK" /etc/config/dhcp; then
		rm -f "$DHCP_BAK"
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
		say "  previous DNS settings restored"
	else
		say "  WARNING: could not restore the DNS settings, a copy is in $DHCP_BAK"
	fi
}
# every instance in $PROXY_USERS gets other upstreams: its remaining ones, else the internet connection's,
# else a public resolver; if none of that resolves, the old settings come back and the script stops
give_back_dns() {
	cp /etc/config/dhcp "$DHCP_BAK" || die "can not back up /etc/config/dhcp, nothing was changed"
	# a lost SSH session must not end the script between the change and the check
	trap '' PIPE
	trap 'restore_dhcp; exit 1' HUP INT TERM
	set -f
	for _i in $PROXY_USERS; do
		for _s in $(uci -q get "dhcp.$_i.server"); do
			if is_proxy "$_s"; then uci del_list "dhcp.$_i.server=$_s"; fi
		done
		for _d in $(ntp_domains); do
			for _ip in $NTP_DNS; do uci -q del_list "dhcp.$_i.server=/$_d/$_ip"; done
		done
		_plain=0
		for _s in $(uci -q get "dhcp.$_i.server"); do case "$_s" in /*) ;; *) _plain=1 ;; esac; done
		[ "$_plain" = 1 ] || uci -q delete "dhcp.$_i.noresolv"
	done
	set +f
	uci commit dhcp && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || { restore_dhcp; die "could not change the DNS settings, nothing was removed"; }
	for _i in $PROXY_USERS; do
		_port=$(uci -q get "dhcp.$_i.port"); _port=${_port:-53}
		[ "$_port" != 0 ] || continue
		resolves "$_port" && { say "  dnsmasq '$_i' resolves without the proxies"; continue; }
		say "  dnsmasq '$_i' got no DNS server from the internet connection: using $FALLBACK_DNS"
		uci add_list "dhcp.$_i.server=$FALLBACK_DNS" && uci commit dhcp && /etc/init.d/dnsmasq restart >/dev/null 2>&1 &&
			resolves "$_port" || { restore_dhcp; die "DNS does not work without the proxies: nothing was removed"; }
	done
	rm -f "$DHCP_BAK"
	trap - INT TERM
	trap '' HUP PIPE
}

[ -f /etc/openwrt_release ] || die "this is not OpenWrt: run it on the router"
[ -z "$(uci -q changes dhcp)" ] || die "/etc/config/dhcp has uncommitted changes: 'uci commit dhcp' or 'uci revert dhcp' first"
if [ -e "$SVC" ]; then
	grep -q '^ABL_UPD_CHANNEL=local-fork' "$SVC" 2>/dev/null ||
		die "the installed adblock-lean is not adblock-lean-plus: use '$SVC uninstall'"
fi

blocker=0; { [ -e "$SVC" ] || [ -d /usr/lib/adblock-lean ]; } && blocker=1
pages=0; { [ -e "$RPCD" ] || [ -d "$VIEWS" ]; } && pages=1
settings=0; [ -d "$CFG" ] && settings=1
doh=0; [ -x /etc/init.d/https-dns-proxy ] && doh=1
# added by the installer: its marker, or the header of the config it writes
doh_ours=0
if [ "$doh" = 1 ] && { [ -f "$DOH_MARK" ] || grep -q '^# https-dns-proxy for adblock-lean-plus' "$DOH_CFG" 2>/dev/null; }; then
	doh_ours=1
fi
if [ "$blocker$pages$settings$doh_ours" = 0000 ] && [ "$REMOVE_DOH" != 1 ]; then
	say "adblock-lean-plus is not installed: nothing to do."
	[ "$DRY" = 1 ] || rm -f "$UPDATE_CMD" "$SELF"
	exit 0
fi
[ "$INTERACTIVE" = 1 ] || [ "$YES" = 1 ] || [ "$DRY" = 1 ] || die "no terminal: add -y to uninstall without questions"

step "adblock-lean-plus uninstaller"
if [ "$settings" = 1 ]; then
	ask KEEP_SETTINGS 0 "Keep your lists and settings ($CFG) for a later install?"
else
	KEEP_SETTINGS=0
fi
if [ "$doh" = 1 ]; then
	[ "$doh_ours" = 1 ] || say "  https-dns-proxy was not set up by this installer (or its marker is gone)"
	ask REMOVE_DOH "$doh_ours" "Remove the DoH proxies (https-dns-proxy)?"
else
	REMOVE_DOH=0
fi
PROXY_USERS=''
if [ "$REMOVE_DOH" = 1 ]; then
	for i in $(instances); do uses_proxies "$i" && PROXY_USERS="$PROXY_USERS $i"; done
elif [ "$doh" = 0 ]; then
	# the proxies are gone already (a firmware upgrade drops added packages) but dnsmasq still forwards to them
	for i in $(instances); do
		uses_proxies "$i" || continue
		answers=0
		for pt in $(doh_ports); do nslookup -type=a -port="$pt" openwrt.org 127.0.0.1 >/dev/null 2>&1 && answers=1; done
		[ "$answers" = 1 ] || PROXY_USERS="$PROXY_USERS $i"
	done
fi

step "Plan: what will be done now"
row() { printf '  %-20s %s\n' "$1:" "$2"; }
row "blocker" "$([ "$blocker" = 1 ] && echo remove || echo 'not installed')"
row "web pages" "$([ "$pages" = 1 ] && echo remove || echo 'not installed')"
if [ "$settings" = 1 ]; then row "lists and settings" "$([ "$KEEP_SETTINGS" = 1 ] && echo keep || echo delete)"; fi
if [ "$REMOVE_DOH" = 1 ]; then row "DoH proxies" remove
elif [ "$doh" = 1 ]; then row "DoH proxies" keep
fi
if [ -n "$PROXY_USERS" ]; then row "DNS" "dnsmasq goes back to the DNS servers of the internet connection"
else row "DNS" unchanged; fi

if [ "$DRY" = 1 ]; then say "
Dry run: nothing was changed."; exit 0; fi
if [ "$INTERACTIVE" = 1 ]; then
	CONFIRM=''
	ask CONFIRM 0 "Uninstall now?"
	[ "$CONFIRM" = 1 ] || { say "Cancelled, nothing was changed."; exit 0; }
fi
failed=''
# from here on a lost SSH session must not leave the removal half done
trap '' HUP PIPE

if [ -n "$PROXY_USERS" ]; then
	step "DNS settings"
	give_back_dns
fi

if [ "$blocker" = 1 ]; then
	step "Blocker"
	# adblock-lean's own uninstall: stops filtering, removes scripts, boot and cron entries and addnmounts.
	# It always keeps the settings here: they (and the DoH marker among them) go at the end, once all else worked.
	if [ -x "$SVC" ]; then
		DO_DIALOGS=0 luci_uninstall_rm_config=n "$SVC" uninstall </dev/null >/dev/null 2>&1
	else
		rm -rf /usr/lib/adblock-lean	# left over from an interrupted removal
	fi
	if [ -e "$SVC" ] || [ -d /usr/lib/adblock-lean ]; then
		say "  WARNING: '$SVC uninstall' did not finish (logread -e adblock-lean)"
		failed="$failed blocker"
	else
		say "  removed"
		rm -f /var/log/abl_session.log*
		# adblock-lean removes its addnmount entries after its last restart of dnsmasq: restart once more,
		# so the running dnsmasq lets go of those paths
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 ||
			{ say "  WARNING: dnsmasq did not restart"; failed="$failed dnsmasq"; }
	fi
fi

if [ "$pages" = 1 ]; then
	step "Web pages"
	rm -f "$RPCD" /usr/share/rpcd/acl.d/luci-app-adblock-lean.json /usr/share/luci/menu.d/luci-app-adblock-lean.json
	rm -rf "$VIEWS" /var/run/luci-adblock-lean /tmp/luci-indexcache* /tmp/luci-modulecache
	/etc/init.d/rpcd reload
	say "  removed"
fi

if [ "$REMOVE_DOH" = 1 ]; then
	step "DoH proxies"
	for p in luci-app-https-dns-proxy https-dns-proxy; do
		pkg_installed "$p" || continue
		if pkg_del "$p" >/dev/null 2>&1 && ! pkg_installed "$p"; then
			say "  removed $p"
		else
			say "  WARNING: could not remove $p ($PKG)"
			failed="$failed $p"
		fi
	done
	pkg_installed https-dns-proxy || rm -f "$DOH_CFG" "$DOH_CFG.apk-new" "$DOH_CFG-opkg" "$DOH_MARK"
fi

# settings kept from an earlier removal, or left behind
if [ "$KEEP_SETTINGS" = 0 ] && [ -z "$failed" ]; then rm -rf /etc/adblock-lean; fi

step "Check"
for i in $(instances); do
	port=$(uci -q get "dhcp.$i.port"); port=${port:-53}
	[ "$port" != 0 ] || continue
	if resolves "$port"; then say "  DNS works (dnsmasq '$i')"
	else say "  WARNING: dnsmasq '$i' does not resolve"; failed="$failed dns"; fi
done
if [ -n "$failed" ]; then
	say "
Finished with problems:$failed. Run the uninstaller again after fixing them."
	exit 1
fi
rm -f "$UPDATE_CMD" "$SELF"
say "
adblock-lean-plus is uninstalled.$([ "$KEEP_SETTINGS" = 1 ] && echo " Your settings are in $CFG.")"
for p in gawk sed coreutils-sort; do
	pkg_installed "$p" && { say "Ordinary packages stay installed (remove them yourself if you added them only for this): gawk, sed, coreutils-sort"; break; }
done
exit 0
