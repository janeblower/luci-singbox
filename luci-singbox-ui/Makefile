include $(TOPDIR)/rules.mk

PKG_NAME:=luci-singbox-ui
PKG_VERSION?=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Jyn

# Conflicts with the legacy iptables-based firewall (fw3); singbox-ui drives
# nftables directly and fw3 would clobber the ruleset on reload.
PKG_CONFLICTS:=firewall

LUCI_TITLE:=LuCI support for singbox-ui
LUCI_DEPENDS:=+luci-base +nftables +sing-box +curl +ucode +ucode-mod-fs +kmod-nft-socket +kmod-nft-tproxy
LUCI_PKGARCH:=all

PO_DIR := $(CURDIR)/po

include $(TOPDIR)/feeds/luci/luci.mk

# PKG_CONFLICTS:=firewall causes opkg/apk to silently remove the legacy
# `firewall` package on install. Surface that explicitly to the operator
# before any state is changed, so they don't lose fw3 rules unawares.
define Package/$(PKG_NAME)/preinst
#!/bin/sh
echo "=============================================================="
echo "INFO: luci-singbox-ui conflicts with package 'firewall'."
echo "If you continue, 'firewall' will be removed and any fw3-based"
echo "rules in /etc/config/firewall will stop being applied."
echo "Make sure no other software depends on fw3 before proceeding."
echo "=============================================================="
exit 0
endef

# Install file set is driven from ../scripts/install-manifest.txt (single
# source of truth, shared with scripts/build-apk.sh). Adding a new file
# means editing one place; tests/test_install_lists_match.sh asserts the
# invariant. The PO → LMO step is handled separately below because po2lmo
# is a host tool invoked at install time, not a static copy.
INSTALL_MANIFEST := $(CURDIR)/../scripts/install-manifest.txt

define Package/$(PKG_NAME)/install
	@while IFS="$$(printf '\t')" read -r src dst mode; do \
	    case "$$src" in '#'*|'') continue ;; esac ; \
	    install -d "$(1)/$$(dirname "$$dst")" ; \
	    case "$$mode" in \
	        bin)  install -m 0755 "./$$src" "$(1)/$$dst" ;; \
	        conf) install -m 0644 "./$$src" "$(1)/$$dst" ;; \
	        data) install -m 0644 "./$$src" "$(1)/$$dst" ;; \
	        *)    echo "install-manifest.txt: unknown mode '$$mode' for $$src" >&2 ; exit 1 ;; \
	    esac ; \
	done < $(INSTALL_MANIFEST)

	if [ -f $(PO_DIR)/ru/luci-singbox-ui.po ]; then \
		$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n; \
		po2lmo $(PO_DIR)/ru/luci-singbox-ui.po \
		       $(1)/usr/lib/lua/luci/i18n/luci-singbox-ui.ru.lmo; \
	fi
endef

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
