#
# luci-app-singbox-ui — LuCI frontend for singbox-ui
#
# Front half of the three-way split:
#   bbolt-client  <-  singbox-ui  <-  luci-app-singbox-ui  <-  luci-i18n-*-ru
#
# Ships only the web views (htdocs -> www), the LuCI menu entry and the rpcd
# ACL. All backend logic lives in the separate `singbox-ui` package, which
# this package depends on. Built with luci.mk (it IS a LuCI app).
#
# PKG_PROVIDES/PKG_REPLACES = luci-singbox-ui so that an `apk`/`opkg` upgrade
# from the old monolith package migrates cleanly onto this split.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-singbox-ui
PKG_VERSION?=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Jyn

# Migrate the retired monolith package (luci-singbox-ui) onto this split.
PKG_PROVIDES:=luci-singbox-ui
PKG_REPLACES:=luci-singbox-ui

LUCI_TITLE:=LuCI support for singbox-ui
# luci-base is pulled in implicitly by luci.mk; +singbox-ui wires the backend.
LUCI_DEPENDS:=+singbox-ui
LUCI_PKGARCH:=all

PO_DIR := $(CURDIR)/po

# Install file set is driven from
# ../scripts/install-manifest-luci-app-singbox-ui.txt (single source of truth,
# shared with scripts/build-apk.sh). htdocs -> www mapping is already encoded
# in the manifest's dst column.
INSTALL_MANIFEST := $(CURDIR)/../scripts/install-manifest-luci-app-singbox-ui.txt

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/install
	@while IFS="$$(printf '\t')" read -r src dst mode; do \
	    case "$$src" in '#'*|'') continue ;; esac ; \
	    install -d "$(1)/$$(dirname "$$dst")" ; \
	    case "$$mode" in \
	        bin)  install -m 0755 "./$$src" "$(1)/$$dst" ;; \
	        conf) install -m 0644 "./$$src" "$(1)/$$dst" ;; \
	        data) install -m 0644 "./$$src" "$(1)/$$dst" ;; \
	        *)    echo "install-manifest-luci-app-singbox-ui.txt: unknown mode '$$mode' for $$src" >&2 ; exit 1 ;; \
	    esac ; \
	done < $(INSTALL_MANIFEST)

	# po2lmo: compile the Russian catalogue. The translation DOMAIN stays
	# `luci-singbox-ui` — do NOT rename the .po / .lmo basename (the JS views
	# call _() against that domain).
	if [ -f $(PO_DIR)/ru/luci-singbox-ui.po ]; then \
		$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n; \
		po2lmo $(PO_DIR)/ru/luci-singbox-ui.po \
		       $(1)/usr/lib/lua/luci/i18n/luci-singbox-ui.ru.lmo; \
	fi
endef

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
