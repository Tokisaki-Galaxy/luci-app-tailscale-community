module("luci.model.tailscale_data", package.seeall)

local sys = require "luci.sys"
local fs = require "luci.fs"
local uci = require "luci.model.uci".cursor()
local jsonc = require "luci.jsonc"
local b64 = require "nixio.util".base64decode

-- 定义一个辅助函数，用于安全地解析 JSON
local function safe_json_parse(str)
    if not str or str == "" then return nil end
    local ok, data = pcall(jsonc.parse, str)
    if ok then return data end
    return nil
end

-- 全局缓存，避免在同一次请求中重复加载
local cached_data = nil

function load()
    if cached_data then
        return cached_data
    end

    local data = {
        running = false,
        ipv4 = _("Not running"),
        ipv6 = nil,
        domain_name = _("Unknown"),
        settings = {},
        daemon_settings = {},
        peers = nil,
        -- 用于 write() 函数比较的原始数据
        _profile_detail_data_raw = nil
    }

    -- 步骤 1: 检查 Tailscale 运行状态
    uci:foreach("tailscale", "daemon", function(s)
        data.daemon_settings = {
            mtu = s.mtu,
            reduce_memory = (s.reduce_memory == "1")
        }
    end)

    local ip_output = sys.exec("tailscale ip 2>/dev/null")
    if not (ip_output and ip_output ~= "") then
        cached_data = data
        return data
    end

    data.running = true
    for line in ip_output:gmatch("[^\r\n]+") do
        if line:match("^(%d{1,3}%.%d{1,3}%.%d{1,3}%.%d{1,3})$") then
            data.ipv4 = line
        elseif line:match(":") then
            data.ipv6 = line
        end
    end

    -- 步骤 2: 读取 state file for settings
    local state_file_path = uci:get("tailscale", "settings", "state_file") or "/etc/tailscale/tailscaled.state"
    if fs.access(state_file_path) then
        local state_content = fs.readfile(state_file_path)
        local state_data = safe_json_parse(state_content)
        if state_data then
            -- ... (解析 state file 的逻辑)
            local profiles_b64 = state_data._profiles
            if profiles_b64 then
                local profiles_json = b64(profiles_b64)
                local profiles_data = safe_json_parse(profiles_json)
                if profiles_data then
                    for _, profile in pairs(profiles_data) do
                        if profile.NetworkProfile and profile.NetworkProfile.DomainName then
                            data.domain_name = profile.NetworkProfile.DomainName
                            break
                        end
                    end
                end
            end

            local profile_key
            for key, _ in pairs(state_data) do if key:match("^profile%-") then profile_key = key; break; end end

            if profile_key and state_data[profile_key] then
                local profile_detail_b64 = state_data[profile_key]
                local profile_detail_json = b64(profile_detail_b64)
                data._profile_detail_data_raw = safe_json_parse(profile_detail_json)

                if data._profile_detail_data_raw then
                    local pdd = data._profile_detail_data_raw
                    data.settings.accept_routes = pdd.RouteAll
                    data.settings.advertise_exit_node = pdd.ExitNodeID == "" and pdd.AdvertiseRoutes and #pdd.AdvertiseRoutes > 0
                    data.settings.advertise_routes = table.concat(pdd.AdvertiseRoutes or {}, ", ")
                    data.settings.exit_node = pdd.ExitNodeID or ""
                    data.settings.exit_node_allow_lan_access = pdd.ExitNodeAllowLANAccess
                    data.settings.hostname = pdd.Hostname or ""
                    data.settings.stateful_filtering = not pdd.NoStatefulFiltering
                    data.settings.snat_subnet_routes = not pdd.NoSNAT
                    data.settings.shields_up = pdd.ShieldsUp
                    data.settings.ssh = pdd.RunSSH
                    data.settings.webclient = pdd.RunWebClient
                    data.settings.auto_update = pdd.AutoUpdate and pdd.AutoUpdate.Check or false
                end
            end
        else
            data.ipv4 = _("State file is invalid JSON")
        end
    else
        data.ipv4 = _("State file not found at: ") .. state_file_path
    end

    -- 步骤 3: 获取所有节点的状态
    local status_output = sys.exec("tailscale status --json 2>/dev/null")
    if status_output and status_output ~= "" then
        local full_status_data = safe_json_parse(status_output)
        if full_status_data and full_status_data.Peer then
            data.peers = {}
            for _, v in pairs(full_status_data.Peer) do table.insert(data.peers, v) end
            table.sort(data.peers, function(a, b) return a.HostName < b.HostName end)
        end
    end

    cached_data = data
    return data
end