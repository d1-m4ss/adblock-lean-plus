# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adblock-lean
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

LUCI_TITLE:=LuCI support for adblock-lean
LUCI_DESCRIPTION:=Status, per-list counts, domain check and list editing for adblock-lean 0.8.x
LUCI_DEPENDS:=+luci-base +rpcd
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
