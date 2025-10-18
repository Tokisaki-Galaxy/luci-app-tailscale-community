
--[[
LuCI - Lua Configuration Interface
Copyright 2024 https://github.com/Tokisaki-Galaxy/luci-app-tailscale-community
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
	http://www.apache.org/licenses/LICENSE-2.0
]]--

m = Map("tailscale", "Tailscale")

s = m:section(TypedSection, "tailscale", "")
s.anonymous = true
s.addremove = false

s:tab("general", _("General Settings"))
s:tab("status",  _("Status"))

-- General Settings Tab
o = s:taboption("general", Flag, "enabled", _("Enable"))
o.rmempty = false

o = s:taboption("general", Flag, "accept_dns", _("Accept DNS"), _("Accept DNS configuration from the admin panel."))
o.rmempty = false

o = s:taboption("general", Flag, "accept_routes", _("Accept routes"), _("Accept routes advertised by other Tailscale nodes."))
o.rmempty = false

o = s:taboption("general", Flag, "advertise_connector", _("Advertise as app connector"), _("Offer to be an app connector for domain specific internet traffic for the tailnet."))
o.rmempty = false

o = s:taboption("general", Flag, "advertise_exit_node", _("Advertise as exit node"), _("Offer to be an exit node for internet traffic for the tailnet."))
o.rmempty = false

o = s:taboption("general", Value, "advertise_routes", _("Advertise routes"), _("Routes to advertise to other nodes (e.g., \"10.0.0.0/8,192.168.0.0/24\")."))
o.rmempty = true

o = s:taboption("general", Value, "exit_node", _("Use exit node"), _("Tailscale exit node (IP, base name, or auto:any) for internet traffic."))
o.rmempty = true

o = s:taboption("general", Flag, "exit_node_allow_lan_access", _("Allow LAN access"), _("Allow direct access to the local network when routing traffic via an exit node."))
o.rmempty = false

o = s:taboption("general", Value, "hostname", _("Hostname"), _("Hostname to use instead of the one provided by the OS."))
o.rmempty = true

o = s:taboption("general", Value, "nickname", _("Nickname"), _("Nickname for the current account."))
o.rmempty = true

o = s:taboption("general", Flag, "report_posture", _("Report device posture"), _("Allow management plane to gather device posture information."))
o.rmempty = false

o = s:taboption("general", Flag, "shields_up", _("Shields up"), _("Don't allow incoming connections."))
o.rmempty = false

o = s:taboption("general", Flag, "ssh", _("Enable SSH server"), _("Run an SSH server, permitting access per tailnet admin's declared policy."))
o.rmempty = false

o = s:taboption("general", Flag, "update_check", _("Check for updates"), _("Notify about available Tailscale updates."))
o.default = o.enabled
o.rmempty = false

o = s:taboption("general", Flag, "webclient", _("Enable web interface"), _("Expose the web interface for managing this node over Tailscale at port 5252."))
o.rmempty = false

o = s:taboption("general", Value, "accept_risk", _("Accept risk"), _("Accept risk and skip confirmation for risk types: lose-ssh, mac-app-connector, linux-strict-rp-filter, all."))
o.rmempty = true

-- Status Tab
s:taboption("status", Button, "_login", _("Login to Tailscale"), _("Click to get the login URL for your Tailscale instance.")).inputstyle = "apply"
s:taboption("status", Button, "_logout", _("Logout from Tailscale"), _("Click to log out from your Tailscale instance.")).inputstyle = "remove"

status = s:taboption("status", Value, "_status", _("Tailscale Status"))
status.readonly = true
status.rows = 20
status.is_json = true
status.wrap = "off"
status.cfgvalue = function(self, section)
	return luci.sys.exec("tailscale status")
end

ip = s:taboption("status", Value, "_ip", _("Tailscale IPs"))
ip.readonly = true
ip.rows = 5
ip.is_json = true
ip.wrap = "off"
ip.cfgvalue = function(self, section)
	return luci.sys.exec("tailscale ip")
end

function m.on_commit(self)
	luci.sys.call("/etc/init.d/tailscale reload >/dev/null")
end

return m
