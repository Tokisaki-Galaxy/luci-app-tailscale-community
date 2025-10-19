module("luci.model.tailscale_data", package.seeall)

local sys = require "luci.sys"
local nixio = require "nixio"
local fs = require "nixio.fs"
local jsonc = require "luci.jsonc"
local util = require "luci.util"

local function base64_decode_cmd(b64_string)
    if not b64_string or b64_string == "" then
        return ""
    end
    -- 使用 luci.util.shellquote 来防止命令注入
    local cmd = string.format("echo %s | base64 -d", util.shellquote(b64_string))
    return sys.exec(cmd)
end

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

    local uci = require "luci.model.uci".cursor()
    local data = {
        running = false,
        ipv4 = "Not running",
        ipv6 = nil,
        domain_name = "Unknown",
        settings = {}, -- 所有配置都将加载到这里
        peers = nil,
        -- 用于 write() 函数比较的原始数据
        _profile_detail_data_raw = nil
    }

    -- 步骤 1: 检查 Tailscale 运行状态
    uci:foreach("tailscale", "settings", function(s)
        -- 将该 section 下的所有 option 复制到 data.settings 表中
        for key, value in pairs(s) do
            if key:sub(1,1) ~= "." then -- 忽略 .name 和 .type
                data.settings[key] = value
            end
        end
    end)

    local ip_output = sys.exec("tailscale ip 2>/dev/null")
    if not (ip_output and ip_output ~= "") then
        cached_data = data
        return data
    end

    data.running = true
    for line in ip_output:gmatch("[^\r\n]+") do
        if line:match(":") then
            --空格前面是ipv4
            data.ipv4 = ip_output:match("^(%S+)")
            data.ipv6 = line
        end
    end

    -- 步骤 2: 读取 state file for runtime settings
    -- 注意：这里获取的设置是 tailscale 运行时动态的设置，而上面从 UCI 加载的是用户保存的配置。
    -- 我们保留 UCI 加载的值，让 state file 的值覆盖它们，以便页面显示最新的状态。
    local state_file_path = data.settings.state_file or "/etc/tailscale/tailscaled.state"
    if fs.access(state_file_path) then
        local state_content = fs.readfile(state_file_path)
        local state_data = safe_json_parse(state_content)
        if state_data then
            -- ... (解析 state file 的逻辑)
            local profiles_b64 = state_data._profiles
            if profiles_b64 then
                local profiles_json = base64_decode_cmd(profiles_b64)
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
                local profile_detail_json = base64_decode_cmd(profile_detail_b64)
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
            data.ipv4 = "State file is invalid JSON"
        end
    else
        data.ipv4 = "State file not found at: " .. state_file_path
    end

    -- 步骤 3: 获取所有节点的状态 (JSON)
    local status_output_json = sys.exec("tailscale status --json 2>/dev/null")
    if status_output_json and status_output_json ~= "" then
        local full_status_data = safe_json_parse(status_output_json)
        if full_status_data and full_status_data.Peer then
            data.peers = {}
            for _, v in pairs(full_status_data.Peer) do table.insert(data.peers, v) end
            table.sort(data.peers, function(a, b) return a.HostName < b.HostName end)
        end
    end

    -- 步骤 4: 获取原始文本状态以补充连接信息
    if data.peers then
        local status_output_plain = sys.exec("tailscale status 2>/dev/null")
        if status_output_plain and status_output_plain ~= "" then
            local connection_info = {}
            for line in status_output_plain:gmatch("[^\r\n]+") do
                local ip, _, _, _, conn_str = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.*)$")
                if ip and conn_str then
                    connection_info[ip] = util.trim(conn_str)
                end
            end

            for _, peer in ipairs(data.peers) do
                if peer.TailscaleIPs and #peer.TailscaleIPs > 0 then
                    local primary_ip = peer.TailscaleIPs[1]
                    if connection_info[primary_ip] then
                        peer.ConnectionInfo = connection_info[primary_ip]
                    end
                end
            end
        end
    end

    cached_data = data
    return data
end