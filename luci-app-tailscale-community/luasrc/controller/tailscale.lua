module("luci.controller.tailscale", package.seeall)

function index()
    -- 检查 tailscale 可执行文件是否存在，如果不存在则不显示菜单
    if not nixio.fs.access("/usr/sbin/tailscale") and not nixio.fs.access("/usr/bin/tailscale") then
        return
    end
    
    entry({"admin", "services", "tailscale"}, alias("admin", "services", "tailscale", "status"), _("Tailscale"), 90).dependent = false
    entry({"admin", "services", "tailscale", "status"}, cbi("tailscale_status"), _("Status"), 1)
    entry({"admin", "services", "tailscale", "settings"}, cbi("tailscale_settings"), _("Settings"), 2)
end