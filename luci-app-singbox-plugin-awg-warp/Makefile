include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-singbox-plugin-awg-warp
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Jyn

LUCI_TITLE:=AWG WARP plugin for luci-app-singbox-ui (Cloudflare WARP + AmneziaWG)
# luci-base is pulled in implicitly by luci.mk.
# singbox-ui is NOT listed here — the dependency is on the UI package
# (which already depends on singbox-ui).
# External runtime components (ip-full, kmod-*, amneziawg-tools, etc.)
# are NOT listed — they are self-provisioned at runtime via plugin rpcd methods.
LUCI_DEPENDS:=+luci-app-singbox-ui
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/description
  AWG WARP plugin for luci-app-singbox-ui.
  Adds Cloudflare WARP registration and AmneziaWG feed provisioning.
  Runtime components (amneziawg-tools, kmod-*, ip-full) are self-provisioned.
endef

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
