include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-sing-box
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Jyn

LUCI_TITLE:=LuCI support for sing-box
LUCI_DEPENDS:=+luci-base +nftables +sing-box
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/sing-box $(1)/etc/config/sing-box

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99-luci-app-sing-box \
	  $(1)/etc/uci-defaults/99-luci-app-sing-box

	$(INSTALL_DIR) $(1)/etc/sing-box
	$(INSTALL_BIN) ./root/etc/sing-box/nftables.sh $(1)/etc/sing-box/nftables.sh

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/sing-box $(1)/usr/libexec/rpcd/sing-box

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-sing-box.json \
	  $(1)/usr/share/luci/menu.d/luci-app-sing-box.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-sing-box.json \
	  $(1)/usr/share/rpcd/acl.d/luci-app-sing-box.json

	$(INSTALL_DIR) $(1)/usr/share/sing-box
	$(INSTALL_DATA) ./root/usr/share/sing-box/generate.lua \
	  $(1)/usr/share/sing-box/generate.lua
	$(INSTALL_DATA) ./root/usr/share/sing-box/sing_box_config.lua \
	  $(1)/usr/share/sing-box/sing_box_config.lua

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/sing-box
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/sing-box/main.js \
	  $(1)/www/luci-static/resources/view/sing-box/main.js
endef

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
