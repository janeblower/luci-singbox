include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-singbox-ui
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Jyn

# Conflicts with the legacy iptables-based firewall (fw3); singbox-ui drives
# nftables directly and fw3 would clobber the ruleset on reload.
PKG_CONFLICTS:=firewall

LUCI_TITLE:=LuCI support for singbox-ui
LUCI_DEPENDS:=+luci-base +nftables +sing-box +curl +ucode +ucode-mod-fs
LUCI_PKGARCH:=all

PO_DIR := $(CURDIR)/po

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/singbox-ui $(1)/etc/config/singbox-ui

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99-luci-app-singbox-ui \
	  $(1)/etc/uci-defaults/99-luci-app-singbox-ui

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/singbox-ui $(1)/etc/init.d/singbox-ui

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/singbox-ui $(1)/usr/libexec/rpcd/singbox-ui

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-singbox-ui.json \
	  $(1)/usr/share/luci/menu.d/luci-app-singbox-ui.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-singbox-ui.json \
	  $(1)/usr/share/rpcd/acl.d/luci-app-singbox-ui.json

	$(INSTALL_DIR) $(1)/usr/share/singbox-ui
	$(INSTALL_DATA) ./root/usr/share/singbox-ui/generate.uc \
	  $(1)/usr/share/singbox-ui/generate.uc
	$(INSTALL_DATA) ./root/usr/share/singbox-ui/subscription.uc \
	  $(1)/usr/share/singbox-ui/subscription.uc
	$(INSTALL_DATA) ./root/usr/share/singbox-ui/nftables.uc \
	  $(1)/usr/share/singbox-ui/nftables.uc

	$(INSTALL_DIR) $(1)/usr/share/singbox-ui/lib
	$(foreach f,$(wildcard ./root/usr/share/singbox-ui/lib/*.uc), \
	  $(INSTALL_DATA) $(f) $(1)/usr/share/singbox-ui/lib/$(notdir $(f));)

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/singbox-ui
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/singbox-ui/main.js \
	  $(1)/www/luci-static/resources/view/singbox-ui/main.js

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/singbox-ui/lib
	$(foreach f,$(wildcard ./htdocs/luci-static/resources/view/singbox-ui/lib/*.js), \
	  $(INSTALL_DATA) $(f) $(1)/www/luci-static/resources/view/singbox-ui/lib/$(notdir $(f));)

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/singbox-ui/importers
	$(foreach f,$(wildcard ./htdocs/luci-static/resources/view/singbox-ui/importers/*.js), \
	  $(INSTALL_DATA) $(f) $(1)/www/luci-static/resources/view/singbox-ui/importers/$(notdir $(f));)

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/singbox-ui/tabs
	$(foreach f,$(wildcard ./htdocs/luci-static/resources/view/singbox-ui/tabs/*.js), \
	  $(INSTALL_DATA) $(f) $(1)/www/luci-static/resources/view/singbox-ui/tabs/$(notdir $(f));)

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/singbox-ui/widgets
	$(foreach f,$(wildcard ./htdocs/luci-static/resources/view/singbox-ui/widgets/*.js), \
	  $(INSTALL_DATA) $(f) $(1)/www/luci-static/resources/view/singbox-ui/widgets/$(notdir $(f));)

	if [ -f $(PO_DIR)/ru/luci-app-singbox-ui.po ]; then \
		$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n; \
		po2lmo $(PO_DIR)/ru/luci-app-singbox-ui.po \
		       $(1)/usr/lib/lua/luci/i18n/luci-app-singbox-ui.ru.lmo; \
	fi
endef

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
