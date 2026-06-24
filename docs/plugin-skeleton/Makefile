#
# luci-singbox-plugin-skeleton — skeleton plugin for luci-app-singbox-ui.
#
# Copy this directory and rename every occurrence of "skeleton" to your plugin
# name (underscore-only: letters, digits, underscores; no dashes).
#

PKG_NAME:=luci-singbox-plugin-skeleton
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

# luci-base is pulled in implicitly by luci.mk.
# Only list luci-app-singbox-ui — not singbox-ui directly (it is already
# a dependency of luci-app-singbox-ui).
# External components this plugin needs at runtime (custom binaries, third-party
# feeds) must NOT appear here — self-provision them via a plugin rpcd method.
LUCI_DEPENDS:=+luci-app-singbox-ui
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/description
  Skeleton plugin for luci-app-singbox-ui.  Replace this with a real
  description of what your plugin does.
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/singbox-ui/lib/plugins/skeleton
	$(INSTALL_DATA) ./root/usr/share/singbox-ui/lib/plugins/skeleton/init.uc \
	    $(1)/usr/share/singbox-ui/lib/plugins/skeleton/init.uc
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-singbox-plugin-skeleton.json \
	    $(1)/usr/share/rpcd/acl.d/luci-singbox-plugin-skeleton.json
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/singbox-ui/plugins/skeleton
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/singbox-ui/plugins/skeleton/tab.js \
	    $(1)/www/luci-static/resources/view/singbox-ui/plugins/skeleton/tab.js
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
