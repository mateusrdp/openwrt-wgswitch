include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI page for wgswitch (Network > VPN)
LUCI_DEPENDS:=+luci-base +wgswitch
LUCI_PKGARCH:=all

PKG_VERSION:=0.1.2
PKG_RELEASE:=1
PKG_MAINTAINER:=Mateus <mateusrdp@users.noreply.github.com>
PKG_LICENSE:=GPL-2.0-only

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
