include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for Tailscale
LUCI_URL:=https://github.com/tokisaki-galaxy/luci-app-tailscale-community
PKG_DESCRIPTION:=Provides a LuCI Web management interface for Tailscale, allowing viewing status, configuring nodes and daemons.
PKG_MAINTAINER:=Tokisaki-Galaxy <moebest@outlook.jp>
LUCI_DEPENDS:=+tailscale +ip +luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-tailscale-community/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	# Run UCI defaults to ensure /etc/config/tailscale exists
	if [ -f /etc/uci-defaults/98-tailscale-community ]; then
		/etc/uci-defaults/98-tailscale-community && rm -f /etc/uci-defaults/98-tailscale-community
	fi
	# Enable the settings helper service so it applies on every boot
	/etc/init.d/tailscale-settings enable 2>/dev/null
	# Clear LuCI menu cache so the new entry appears immediately
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	# Reload rpcd to register the new ACL and ucode plugin
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
endef

define Package/luci-app-tailscale-community/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/tailscale-settings disable 2>/dev/null
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	exit 0
}
endef

# call BuildPackage - OpenWrt buildroot signature
