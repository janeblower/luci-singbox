#
# bbolt-client — per-arch bbolt cache.db reader for singbox-ui
#
# Bottom of the three-way split:
#   bbolt-client  <-  singbox-ui  <-  luci-app-singbox-ui  <-  luci-i18n-*-ru
#
# THIN package on purpose. The authoritative binary is a no_std raw-syscall
# Rust client cross-compiled for 5 ABIs (x86_64 / aarch64 / armv7 / mipsel /
# mips) by bbolt-client/build.sh, and embedded per-arch into the shipped .apk
# by scripts/build-apk.sh. The real install path for end users is that .apk,
# not an in-buildroot Rust toolchain build.
#
# OUT OF SCOPE (spec decision C): a full in-buildroot cargo cross-compile.
# Wiring nightly Rust + 5-ABI cross targets through OpenWrt's buildroot is
# deliberately NOT attempted here. Build/Compile below is a documented no-op;
# Package/install best-effort copies a prebuilt ./bbolt-client-rs-* binary if
# one happens to be present in the source tree (e.g. after `./build.sh`).
#

include $(TOPDIR)/rules.mk

PKG_NAME:=bbolt-client
PKG_VERSION?=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Jyn

include $(TOPDIR)/include/package.mk

define Package/$(PKG_NAME)
  SECTION:=net
  CATEGORY:=Network
  TITLE:=bbolt cache.db reader for singbox-ui
  URL:=https://github.com/janeblower/luci-singbox
  # libc only — the binary is a static no_std raw-syscall reader.
  DEPENDS:=+libc
  PROVIDES:=bbolt-client-any
endef

define Package/$(PKG_NAME)/description
  bbolt cache.db reader for singbox-ui. Reads sing-box's compiled rule-sets out
  of the bbolt cache (cache.db) so the nftables driver can build nftsets without
  re-fetching. Authoritative binary is cross-built by bbolt-client/build.sh and
  embedded per-arch by scripts/build-apk.sh.
endef

# No-op build. The real binary comes from bbolt-client/build.sh (cargo +
# the 5-ABI cross build) and is embedded by scripts/build-apk.sh. A full
# in-buildroot Rust compile is intentionally out of scope (spec decision C).
define Build/Prepare
endef
define Build/Configure
endef
define Build/Compile
	@echo "bbolt-client: in-buildroot Rust compile is out of scope (spec C)."
	@echo "bbolt-client: authoritative binary built by ./build.sh and embedded by scripts/build-apk.sh."
endef

# Best-effort install: if a prebuilt ./bbolt-client-rs-* binary is present in
# the source tree (e.g. left by ./build.sh), ship it as the canonical path
# /usr/libexec/singbox-ui/bbolt-client. Otherwise install nothing here — the
# real per-arch binary is embedded by scripts/build-apk.sh at packaging time.
define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/libexec/singbox-ui
	@bin=$$$$(ls ./bbolt-client-rs-* 2>/dev/null | head -n1); \
	if [ -n "$$$$bin" ] && [ -f "$$$$bin" ]; then \
	    echo "bbolt-client: embedding prebuilt $$$$bin"; \
	    $(INSTALL_BIN) "$$$$bin" $(1)/usr/libexec/singbox-ui/bbolt-client; \
	else \
	    echo "bbolt-client: no prebuilt ./bbolt-client-rs-* found; binary embedded by scripts/build-apk.sh instead"; \
	fi
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
