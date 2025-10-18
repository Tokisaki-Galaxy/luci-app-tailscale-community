
module("luci.controller.tailscale", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/tailscale") then
		return
	end

	entry({"admin", "services", "tailscale"}, cbi("tailscale"), _("Tailscale"), 10).dependent = true

	entry({"admin", "services", "tailscale", "status"}, call("act_status")).leaf = true
end

function act_status()
	local e = {}
	e.status = luci.sys.exec("tailscale status")
	e.ip = luci.sys.exec("tailscale ip")
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end
