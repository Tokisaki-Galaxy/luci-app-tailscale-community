local sys = require "luci.sys"
local fs = require "luci.fs"
local uci = require "luci.model.uci".cursor()
local jsonc = require "luci.jsonc"
local b64 = require "nixio.util".base64decode
local util = require "luci.util"

-- 定义一个辅助函数，用于安全地解析 JSON
local function safe_json_parse(str)
    if not str or str == "" then return nil end
    local ok, data = pcall(jsonc.parse, str)
    if ok then
        return data
    end
    return nil
end

-- 创建 CBI Map, 但我们不会用它来直接管理 UCI
m = Map("tailscale", "Tailscale")
m.redirect = luci.dispatcher.build_url("admin", "services", "tailscale")

-- #################################
--  Data Loading Section
-- #################################

-- 初始化一个 table 来存储所有从状态文件读取的信息
local status = {
    running = false,
    ipv4 = _("Not running"),
    ipv6 = "",
    domain_name = _("Unknown"),
    -- 从 profile-*.json 中读取的详细设置
    settings = {}
}
local profile_detail_data = nil

-- 步骤 1: 检查 Tailscale 运行状态
local ip_output = sys.exec("tailscale ip 2>/dev/null")
if ip_output and ip_output ~= "" then
    status.running = true
    for line in ip_output:gmatch("[^\r\n]+") do
        if line:match("^(%d{1,3}%.%d{1,3}%.%d{1,3}%.%d{1,3})$") then
            status.ipv4 = line
        elseif line:match(":") then
            status.ipv6 = line
        end
    end
else
    -- 如果命令失败，则保持默认的 "Not running" 状态
end

-- 步骤 2 & 3: 如果正在运行，则读取状态文件并解析
if status.running then
    local state_file_path = uci:get("tailscale", "settings", "state_file") or "/etc/tailscale/tailscaled.state"

    if fs.access(state_file_path) then
        local state_content = fs.readfile(state_file_path)
        local state_data = safe_json_parse(state_content)

        if state_data then
            -- 解析 _profiles 以获取域名
            local profiles_b64 = state_data._profiles
            if profiles_b64 then
                local profiles_json = b64(profiles_b64)
                local profiles_data = safe_json_parse(profiles_json)
                if profiles_data then
                    for _, profile in pairs(profiles_data) do
                        if profile.NetworkProfile and profile.NetworkProfile.DomainName then
                            status.domain_name = profile.NetworkProfile.DomainName
                            break
                        end
                    end
                end
            end

            -- 查找并解析 profile-*
            local profile_key
            for key, _ in pairs(state_data) do
                if key:match("^profile%-") then
                    profile_key = key
                    break
                end
            end

            if profile_key and state_data[profile_key] then
                local profile_detail_b64 = state_data[profile_key]
                local profile_detail_json = b64(profile_detail_b64)
                profile_detail_data = safe_json_parse(profile_detail_json)
            end
        else
            status.ipv4 = _("State file is invalid JSON")
        end
    else
        status.ipv4 = _("State file not found at: ") .. state_file_path
    end
end


-- #################################
--  Status Display Section
-- #################################

s = m:section(TypedSection, "tailscale_status", _("Status"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_status", _("Service Status"))
o.value = status.running and ('<span style="color:green;">' .. _("Running") .. '</span>') or ('<span style="color:red;">' .. _("Not Running") .. '</span>')
o.rawhtml = true

o = s:option(DummyValue, "_ipv4", _("Tailscale IPv4"))
o.value = status.ipv4

o = s:option(DummyValue, "_ipv6", _("Tailscale IPv6"))
o.value = (status.ipv6 and status.ipv6 ~= "") and status.ipv6 or _("N/A")

o = s:option(DummyValue, "_domain", _("Tailnet Name"))
o.value = status.domain_name

-- #################################
--  Settings Section
-- #################################

-- 只有成功解析了状态文件后，才显示设置区域
if profile_detail_data then

    -- 填充 status.settings table
    status.settings.accept_routes = profile_detail_data.RouteAll
    status.settings.advertise_exit_node = profile_detail_data.ExitNodeID == "" and profile_detail_data.AdvertiseRoutes and #profile_detail_data.AdvertiseRoutes > 0 -- Heuristic
    status.settings.advertise_routes = table.concat(profile_detail_data.AdvertiseRoutes or {}, ", ")
    status.settings.exit_node = profile_detail_data.ExitNodeID or ""
    status.settings.exit_node_allow_lan_access = profile_detail_data.ExitNodeAllowLANAccess
    status.settings.hostname = profile_detail_data.Hostname or ""
    -- 注意: NoStatefulFiltering 是反向的
    status.settings.stateful_filtering = not profile_detail_data.NoStatefulFiltering
    -- 注意: NoSNAT 是反向的
    status.settings.snat_subnet_routes = not profile_detail_data.NoSNAT
    status.settings.shields_up = profile_detail_data.ShieldsUp
    status.settings.ssh = profile_detail_data.RunSSH
    status.settings.webclient = profile_detail_data.RunWebClient
    status.settings.auto_update = profile_detail_data.AutoUpdate and profile_detail_data.AutoUpdate.Check or false


    s_set = m:section(TypedSection, "settings", _("Settings"))
    s_set.anonymous = true
    s_set.addremove = false

    -- ## Network Settings ##
    o = s_set:option(Flag, "accept_routes", _("Accept Routes"))
    o.description = _("Allow this node to receive routes advertised by other nodes in your tailnet.")
    o.default = status.settings.accept_routes and "1" or "0"
    o.rmempty = false

    o = s_set:option(Flag, "advertise_exit_node", _("Advertise as Exit Node"))
    o.description = _("Offer this node as an exit node for other devices in your tailnet.")
    o.default = status.settings.advertise_exit_node and "1" or "0"
    o.rmempty = false
    
    o = s_set:option(Value, "advertise_routes", _("Advertise Routes"))
    o.description = _("Comma-separated list of local subnets to advertise, e.g., 192.168.1.0/24,10.0.0.0/16")
    o.default = status.settings.advertise_routes
    o.rmempty = true

    o = s_set:option(Value, "exit_node", _("Use Exit Node"))
    o.description = _("Enter the IP or name of a Tailscale exit node to route all internet traffic through. Leave empty to disable.")
    o.default = status.settings.exit_node
    o.rmempty = true

    o = s_set:option(Flag, "exit_node_allow_lan_access", _("Allow LAN Access via Exit Node"))
    o.description = _("When using an exit node, still allow direct access to the local network.")
    o.default = status.settings.exit_node_allow_lan_access and "1" or "0"
    o.rmempty = false

    o = s_set:option(Flag, "snat_subnet_routes", _("Enable SNAT for Subnet Routes"))
    o.description = _("Source NAT traffic from clients to your advertised subnets. Usually required.")
    o.default = status.settings.snat_subnet_routes and "1" or "0"
    o.rmempty = false

    -- ## Node Settings ##
    o = s_set:option(Flag, "ssh", _("Enable SSH Server"))
    o.description = _("Run Tailscale's built-in SSH server.")
    o.default = status.settings.ssh and "1" or "0"
    o.rmempty = false
    
    o = s_set:option(Flag, "shields_up", _("Shields Up Mode"))
    o.description = _("Block all incoming connections from other nodes in your tailnet. This node can still make outgoing connections.")
    o.default = status.settings.shields_up and "1" or "0"
    o.rmempty = false

    o = s_set:option(Flag, "auto_update", _("Enable Auto-Updates"))
    o.description = _("Allow Tailscale to automatically update itself to the latest version.")
    o.default = status.settings.auto_update and "1" or "0"
    o.rmempty = false

    o = s_set:option(Value, "hostname", _("Custom Hostname"))
    o.description = _("Set a custom hostname for this node within Tailscale. Leave empty to use the system hostname.")
    o.default = status.settings.hostname
    o.rmempty = true
    
end

-- #################################
--  Custom Write Logic
-- #################################

function m.write(self, ...)
    local data = luci.cbi.apply_xhr_validation()
    local args = {}

    -- 辅助函数，用于比较值并生成参数
    local function add_arg_if_changed(flag_name, old_val, new_val, is_bool)
        if old_val ~= new_val then
            if is_bool then
                table.insert(args, util.format("--%s=%s", flag_name, new_val and "true" or "false"))
            else
                -- 对于字符串，需要用引号包裹，特别是空字符串
                table.insert(args, util.format("--%s=\"%s\"", flag_name, new_val or ""))
            end
        end
    end

    if profile_detail_data then
        -- 比较布尔值 (Checkbox/Flag)
        add_arg_if_changed("accept-routes", status.settings.accept_routes, data.accept_routes == "1", true)
        add_arg_if_changed("advertise-exit-node", status.settings.advertise_exit_node, data.advertise_exit_node == "1", true)
        add_arg_if_changed("exit-node-allow-lan-access", status.settings.exit_node_allow_lan_access, data.exit_node_allow_lan_access == "1", true)
        add_arg_if_changed("snat-subnet-routes", status.settings.snat_subnet_routes, data.snat_subnet_routes == "1", true)
        add_arg_if_changed("ssh", status.settings.ssh, data.ssh == "1", true)
        add_arg_if_changed("shields-up", status.settings.shields_up, data.shields_up == "1", true)
        add_arg_if_changed("auto-update", status.settings.auto_update, data.auto_update == "1", true)

        -- 比较字符串值 (Value)
        add_arg_if_changed("advertise-routes", status.settings.advertise_routes, data.advertise_routes, false)
        add_arg_if_changed("exit-node", status.settings.exit_node, data.exit_node, false)
        add_arg_if_changed("hostname", status.settings.hostname, data.hostname, false)
    end
    
    if #args > 0 then
        local cmd = "tailscale set " .. table.concat(args, " ")
        -- 执行命令。使用 sys.call 以便等待命令完成
        sys.call(cmd .. " >/dev/null 2>&1")
        -- 等待，让 tailscaled 守护进程有时间处理变化并更新状态文件
        sys.call("sleep 2")
    end
    
    -- 不需要调用父类的 write 方法，因为我们不写任何 UCI 文件
    return
end


return m