include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for Tailscale
PKG_DESCRIPTION:=为 Tailscale 提供 LuCI Web 管理界面，允许查看状态、配置节点和守护进程。
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Tokisaki-Galaxy <moebest@outlook.jp>
LUCI_DEPENDS:=+tailscale +coreutils-base64
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
