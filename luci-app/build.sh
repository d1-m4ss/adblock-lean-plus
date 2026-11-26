#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Build luci-app-adblock-lean as a signed apk and refresh the apk repository in apk/.
# No buildroot needed. Needs apk-tools 3 (APK=path/to/apk, e.g. an Image Builder's
# staging_dir/host/bin/apk), the repository's private key (KEY=path) and sudo, so
# the files in the package are owned by root.
set -e
cd "$(dirname "$0")"
PKG=luci-app-adblock-lean
APK=${APK:?set APK to an apk-tools 3 binary}
KEY=${KEY:?set KEY to the repository signing key}
VER=$(sed -n 's/^PKG_VERSION:=//p' $PKG/Makefile)-r$(sed -n 's/^PKG_RELEASE:=//p' $PKG/Makefile)
ST=$(mktemp -d)
mkdir -p "$ST/www" && cp -a $PKG/root/. "$ST/" && cp -a $PKG/htdocs/. "$ST/www/"
chmod 755 "$ST/usr/libexec/rpcd/$PKG"*  2>/dev/null || true
chmod 755 "$ST/usr/libexec/rpcd/luci.adblock-lean"
sudo chown -R 0:0 "$ST"
mkdir -p apk
rm -f apk/$PKG-*.apk
sudo "$APK" mkpkg -F "$ST" -o "apk/$PKG-$VER.apk" --sign-key "$KEY" \
  -I name:$PKG -I "version:$VER" \
  -I "description:LuCI support for adblock-lean: status, per-list counts, domain check and list editing" \
  -I arch:noarch -I license:GPL-2.0-only -I origin:$PKG \
  -I "url:https://github.com/Wildside-UK/luci-app-adblock-lean" \
  -I "depends:luci-base rpcd" \
  -s post-install:$PKG/scripts/post-install -s post-upgrade:$PKG/scripts/post-upgrade \
  -s post-deinstall:$PKG/scripts/post-deinstall
sudo rm -rf "$ST"
sudo "$APK" mkndx --allow-untrusted --sign-key "$KEY" -o apk/packages.adb apk/*.apk
sudo chown "$(id -u):$(id -g)" apk/*
ls -l apk
