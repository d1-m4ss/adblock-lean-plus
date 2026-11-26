#!/bin/sh
# Downloads the latest adblock-lean-plus on the router and runs its installer; options are passed on.
#
#   wget -qO /tmp/get.sh https://raw.githubusercontent.com/d1-m4ss/adblock-lean-plus/main/get.sh && sh /tmp/get.sh
#
# The installer puts a copy at /usr/sbin/adblock-lean-plus-update: run that to update an installation.
# SPDX-License-Identifier: GPL-2.0-only
# All in a function that runs after the whole file is read: a half downloaded script does nothing, and an
# update may replace this file while it runs.
main() {
	# codeload.github.com: OpenWrt's wget hangs on github.com links (a response header is too long for it)
	url=https://codeload.github.com/d1-m4ss/adblock-lean-plus/tar.gz/refs/heads/main
	dir=/tmp/ablp
	[ -f /etc/openwrt_release ] || { echo "Run this on the OpenWrt router (ssh root@192.168.1.1)."; return 1; }
	case "$0" in *adblock-lean-plus-update) set -- --upgrade "$@" ;; esac
	rm -rf "$dir"
	mkdir -p "$dir" || return 1
	echo "Downloading adblock-lean-plus ..."
	if ! wget -q -T 30 -O "$dir/ablp.tar.gz" "$url"; then
		echo "ERROR: could not download $url (is the router online and does DNS work?)"
		rm -rf "$dir"
		return 1
	fi
	if ! tar -C "$dir" -xzf "$dir/ablp.tar.gz" || ! cd "$dir"/adblock-lean-plus-*; then
		echo "ERROR: the downloaded archive is damaged"
		rm -rf "$dir"
		return 1
	fi
	rc=0
	sh install.sh "$@" || rc=$?
	cd /
	rm -rf "$dir"
	return "$rc"
}
{ main "$@"; exit $?; }
