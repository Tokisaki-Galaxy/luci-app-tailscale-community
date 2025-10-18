local util = require "luci.util"
local sys = require "luci.sys"
local data_loader = require "luci.model.tailscale_data"

-- 加载所有数据
local data = data_loader.load()

m = Map("tailscale", "Tailscale Settings")
m.redirect = luci.dispatcher.build_url("admin", "services", "tailscale", "settings")

-- 只有在成功解析了设置后，才显示设置表单
if data._profile_detail_data_raw then
    s_set = m:section(TypedSection, "settings", _("Settings"))
    s_set.anonymous = true
    
    o = s_set:option(Flag, "accept_routes", _("Accept Routes"), _("Allow this node to receive routes advertised by other nodes in your tailnet."))
    o.default = data.settings.accept_routes and "1" or "0"; o.rmempty = false

    o = s_set:option(Flag, "advertise_exit_node", _("Advertise as Exit Node"), _("Offer this node as an exit node for other devices in your tailnet."))
    o.default = data.settings.advertise_exit_node and "1" or "0"; o.rmempty = false
    
    o = s_set:option(Value, "advertise_routes", _("Advertise Routes"), _("Comma-separated list of local subnets to advertise, e.g., 192.168.1.0/24,10.0.0.0/16"))
    o.default = data.settings.advertise_routes; o.rmempty = true

    o = s_set:option(Value, "exit_node", _("Use Exit Node"), _("Enter the IP or name of a Tailscale exit node to route all internet traffic through. Leave empty to disable."))
    o.default = data.settings.exit_node; o.rmempty = true

    o = s_set:option(Flag, "exit_node_allow_lan_access", _("Allow LAN Access via Exit Node"), _("When using an exit node, still allow direct access to the local network."))
    o.default = data.settings.exit_node_allow_lan_access and "1" or "0"; o.rmempty = false

    o = s_set:option(Flag, "snat_subnet_routes", _("Enable SNAT for Subnet Routes"), _("Source NAT traffic from clients to your advertised subnets. Usually required."))
    o.default = data.settings.snat_subnet_routes and "1" or "0"; o.rmempty = false

    o = s_set:option(Flag, "ssh", _("Enable SSH Server"), _("Run Tailscale's built-in SSH server."))
    o.default = data.settings.ssh and "1" or "0"; o.rmempty = false
    
    o = s_set:option(Flag, "shields_up", _("Shields Up Mode"), _("Block all incoming connections from other nodes in your tailnet. This node can still make outgoing connections."))
    o.default = data.settings.shields_up and "1" or "0"; o.rmempty = false

    o = s_set:option(Flag, "auto_update", _("Enable Auto-Updates"), _("Allow Tailscale to automatically update itself to the latest version."))
    o.default = data.settings.auto_update and "1" or "0"; o.rmempty = false

    o = s_set:option(Value, "hostname", _("Custom Hostname"), _("Set a custom hostname for this node within Tailscale. Leave empty to use the system hostname."))
    o.default = data.settings.hostname; o.rmempty = true
else
    s_err = m:section(TypedSection, "error", _("Settings Unavailable"))
    s_err.anonymous = true
    s_err.description = _("Settings cannot be loaded. Please ensure Tailscale is running and properly configured.")
end

function m.write(self, ...)
    local form_data = luci.cbi.apply_xhr_validation()
    local args = {}

    local function add_arg_if_changed(flag_name, old_val, new_val, is_bool)
        if old_val ~= new_val then
            if is_bool then
                table.insert(args, util.format("--%s=%s", flag_name, new_val and "true" or "false"))
            else
                table.insert(args, util.format("--%s=\"%s\"", flag_name, new_val or ""))
            end
        end
    end

    if data._profile_detail_data_raw then
        add_arg_if_changed("accept-routes", data.settings.accept_routes, form_data.accept_routes == "1", true)
        add_arg_if_changed("advertise-exit-node", data.settings.advertise_exit_node, form_data.advertise_exit_node == "1", true)
        add_arg_if_changed("exit-node-allow-lan-access", data.settings.exit_node_allow_lan_access, form_data.exit_node_allow_lan_access == "1", true)
        add_arg_if_changed("snat-subnet-routes", data.settings.snat_subnet_routes, form_data.snat_subnet_routes == "1", true)
        add_arg_if_changed("ssh", data.settings.ssh, form_data.ssh == "1", true)
        add_arg_if_changed("shields-up", data.settings.shields_up, form_data.shields_up == "1", true)
        add_arg_if_changed("auto-update", data.settings.auto_update, form_data.auto_update == "1", true)
        add_arg_if_changed("advertise-routes", data.settings.advertise_routes, form_data.advertise_routes, false)
        add_arg_if_changed("exit-node", data.settings.exit_node, form_data.exit_node, false)
        add_arg_if_changed("hostname", data.settings.hostname, form_data.hostname, false)
    end
    
    if #args > 0 then
        local cmd = "tailscale set " .. table.concat(args, " ")
        sys.call(cmd .. " >/dev/null 2>&1")
        sys.call("sleep 2") -- 增加等待时间以确保状态文件更新
    end
    
    return
end

return m