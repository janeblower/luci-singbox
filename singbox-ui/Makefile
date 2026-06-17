#
# singbox-ui — backend (ucode generators, rpcd handler, init.d, nft driver)
#
# This is the arch-independent (noarch) BACKEND package of the three-way split:
#   bbolt-client  <-  singbox-ui  <-  luci-app-singbox-ui  <-  luci-i18n-*-ru
#
# It ships NO LuCI views, so it is a plain OpenWrt package built with
# include $(TOPDIR)/rules.mk + BuildPackage — NOT luci.mk. The LuCI frontend
# lives in the separate luci-app-singbox-ui package, which depends on this one.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=singbox-ui
PKG_VERSION?=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Jyn

# Conflicts with the legacy iptables-based firewall (fw3); singbox-ui drives
# nftables directly and fw3 would clobber the ruleset on reload. 'nftables'
# itself is part of the OpenWrt base (fw4) and is therefore NOT listed as a
# dependency. 'jq' is likewise not used on-device and intentionally absent.
PKG_CONFLICTS:=firewall

# Install file set is driven from ../scripts/install-manifest-singbox-ui.txt
# (single source of truth, shared with scripts/build-apk.sh).
INSTALL_MANIFEST := $(CURDIR)/../scripts/install-manifest-singbox-ui.txt

include $(TOPDIR)/include/package.mk

define Package/$(PKG_NAME)
  SECTION:=net
  CATEGORY:=Network
  TITLE:=sing-box UI backend (config generator, rpcd, nftables driver)
  URL:=https://github.com/janeblower/luci-singbox
  # CANON dep line — keep in sync with APP_DEPENDS in scripts/build-apk.sh.
  # NB: 'nftables' (base/fw4) and 'jq' are deliberately excluded.
  DEPENDS:=+bbolt-client +sing-box +curl +ucode +ucode-mod-fs +kmod-nft-socket +kmod-nft-tproxy
  PKGARCH:=all
  PROVIDES:=singbox-ui-any
endef

define Package/$(PKG_NAME)/description
  Backend for the sing-box LuCI app: UCI->JSON config generators (ucode),
  the singbox-ui rpcd handler, the procd service, the nftables/tproxy driver,
  and the subscription / rule-set fetchers. The LuCI web UI is shipped
  separately by luci-app-singbox-ui.
endef

# PKG_CONFLICTS:=firewall causes apk/opkg to silently remove the legacy
# `firewall` package on install. Surface that explicitly to the operator
# before any state is changed, so they don't lose fw3 rules unawares.
define Package/$(PKG_NAME)/preinst
#!/bin/sh
echo "=============================================================="
echo "INFO: singbox-ui conflicts with package 'firewall'."
echo "If you continue, 'firewall' will be removed and any fw3-based"
echo "rules in /etc/config/firewall will stop being applied."
echo "Make sure no other software depends on fw3 before proceeding."
echo "=============================================================="
exit 0
endef

# /etc/config/singbox-ui is operator state — mark it a conffile so upgrades
# don't clobber a customised configuration.
define Package/$(PKG_NAME)/conffiles
/etc/config/singbox-ui
endef

# Build/* are no-ops: this package ships pre-written sources, nothing compiles.
define Build/Prepare
endef
define Build/Configure
endef
define Build/Compile
endef

# Install file set from ../scripts/install-manifest-singbox-ui.txt.
# Same tab-separated while-read loop as the old monolith Makefile; modes are
# bin (0755) / conf (0644) / data (0644).
define Package/$(PKG_NAME)/install
	@while IFS="$$(printf '\t')" read -r src dst mode; do \
	    case "$$src" in '#'*|'') continue ;; esac ; \
	    install -d "$(1)/$$(dirname "$$dst")" ; \
	    case "$$mode" in \
	        bin)  install -m 0755 "./$$src" "$(1)/$$dst" ;; \
	        conf) install -m 0644 "./$$src" "$(1)/$$dst" ;; \
	        data) install -m 0644 "./$$src" "$(1)/$$dst" ;; \
	        *)    echo "install-manifest-singbox-ui.txt: unknown mode '$$mode' for $$src" >&2 ; exit 1 ;; \
	    esac ; \
	done < $(INSTALL_MANIFEST)
endef

# Enable and start the procd service after install/upgrade.
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
if [ -x /etc/init.d/singbox-ui ]; then
	/etc/init.d/singbox-ui enable
	/etc/init.d/singbox-ui start
fi
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
