# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adblock-lean
PKG_VERSION:=0.2.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

LUCI_TITLE:=LuCI support for adblock-lean
LUCI_DESCRIPTION:=Status, subscriptions, update schedule and domain check for adblock-lean-plus (next-version layout)
LUCI_DEPENDS:=+luci-base +rpcd
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
