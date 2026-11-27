#!/bin/sh
# Checks run by CI inside an OpenWrt rootfs container, so with its BusyBox shell and tools; works on a router too.
# usage: sh tools/ci.sh
cd "$(dirname "$0")/.." || exit 1
rv=0

echo "== shell syntax"
for f in install.sh get.sh uninstall.sh tools/*.sh adblock-lean/adblock-lean adblock-lean/*.sh \
	adblock-lean/usr/lib/adblock-lean/*.sh adblock-lean/etc/adblock-lean/*.sh adblock-lean/tests/*.sh \
	luci-app/luci-app-adblock-lean/root/usr/libexec/rpcd/luci.adblock-lean
do
	[ -f "${f}" ] || { echo "missing: ${f}"; rv=1; continue; }
	sh -n "${f}" || { echo "syntax error: ${f}"; rv=1; }
done

for t in adblock-lean/tests/test-*.sh
do
	echo "== ${t}"
	sh "${t}" || rv=1
done

[ "${rv}" = 0 ] && echo "ALL PASSED" || echo "FAILED"
exit "${rv}"
