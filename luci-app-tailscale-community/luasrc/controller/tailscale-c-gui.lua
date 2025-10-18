module("luci.controller.tailscale-c-gui", package.seeall)

function index()
    -- 定义菜单项在 "服务" -> "Tailscale Status"
    -- 如果您有 "luci-app-tailscale"，可能会想把它放在同一个父菜单下
    entry({"admin", "services", "tailscale_status"}, cbi("tailscale-c-gui"), _("Tailscale Status"), 20).dependent = true
end