include $(TOPDIR)/rules.mk

PKG_NAME:=wgswitch
PKG_VERSION:=0.1.2
PKG_RELEASE:=1

PKG_MAINTAINER:=Mateus <mateusrdp@users.noreply.github.com>
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/wgswitch
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=WireGuard client profile switcher with health checks and kill switch
  URL:=https://github.com/mateusrdp/openwrt-wgswitch
  DEPENDS:=+wireguard-tools +kmod-wireguard +ip-full
  PKGARCH:=all
endef

define Package/wgswitch/description
  Keeps a folder of WireGuard client profiles (wg-quick .conf files),
  connects one at a time through a single netifd interface, tests every
  profile with a real WireGuard handshake to find the fastest server,
  and watches the live tunnel with a kill switch (block / switch to the
  fastest / fall back to direct).
endef

define Package/wgswitch/conffiles
/etc/config/wgswitch
endef

define Build/Compile
endef

define Package/wgswitch/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/usr/lib/wgswitch $(1)/etc/init.d \
		$(1)/etc/config $(1)/lib/upgrade/keep.d $(1)/etc/wireguard
	$(INSTALL_BIN) ./files/wgswitch $(1)/usr/sbin/wgswitch
	$(SED) 's/@VERSION@/$(PKG_VERSION)-r$(PKG_RELEASE)/' $(1)/usr/sbin/wgswitch
	$(INSTALL_DATA) ./files/lib.sh $(1)/usr/lib/wgswitch/lib.sh
	$(INSTALL_BIN) ./files/wgswitch.init $(1)/etc/init.d/wgswitch
	$(INSTALL_CONF) ./files/wgswitch.config $(1)/etc/config/wgswitch
	$(INSTALL_DATA) ./files/wgswitch.keep $(1)/lib/upgrade/keep.d/wgswitch
endef

define Package/wgswitch/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
chmod 700 /etc/wireguard 2>/dev/null
chmod 600 /etc/wireguard/*.conf 2>/dev/null
exit 0
endef

$(eval $(call BuildPackage,wgswitch))
