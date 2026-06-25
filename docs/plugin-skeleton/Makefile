#
# singbox-ui-plugin-skeleton — skeleton plugin for luci-app-singbox-ui.
#
# Copy docs/plugin-skeleton/ and rename every occurrence of "skeleton" to
# your plugin name (underscore-only: letters, digits, underscores; no dashes).
#
# This Makefile is for the OpenWrt buildroot.  To build a standalone .apk
# without the buildroot, use scripts/build-apk.sh instead (add a section
# mirroring the awg_warp plugin: see the "5) singbox-ui-plugin-awg_warp"
# block in that script).
#

PKG_NAME:=singbox-ui-plugin-skeleton
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

# luci-base is pulled in implicitly by luci.mk.
# Only list luci-app-singbox-ui — not singbox-ui directly (it is already
# a dependency of luci-app-singbox-ui).
# External components this plugin needs at runtime (kernel modules, helper
# binaries, third-party feeds) must NOT appear here — self-provision them
# via a plugin rpcd method at runtime (see docs/plugins.md).
LUCI_DEPENDS:=+luci-app-singbox-ui
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/description
  Skeleton plugin for luci-app-singbox-ui.  Replace this with a real
  description of what your plugin does.
endef

define Package/$(PKG_NAME)/install
	# lib/ → /usr/share/singbox-ui/lib/plugins/skeleton/ (includes protocols/).
	# This is the framework discovery path: discovery.uc globs */init.uc there.
	$(INSTALL_DIR) $(1)/usr/share/singbox-ui/lib/plugins/skeleton
	$(CP) ./lib/. $(1)/usr/share/singbox-ui/lib/plugins/skeleton/

	# root/ → / (rootfs overlay: acl.d, libexec scripts, etc.)
	$(CP) ./root/. $(1)/

	# htdocs/ → www/ (LuCI static serving convention).
	$(INSTALL_DIR) $(1)/www
	$(CP) ./htdocs/. $(1)/www/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
