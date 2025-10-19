local util = require "luci.util"
local sys = require "luci.sys"
local nixio = require "nixio"
local fs = require "nixio.fs"
local data_loader = require "luci.model.tailscale_data"
local i18n = require "luci.i18n"
local cbi = require "luci.cbi"
_ = i18n.translate

-- 加载所有数据
local data = data_loader.load()

m = Map("tailscale", _("Tailscale"))
m:chain("luci")

m.old_settings = {}
if data.settings then
    for k, v in pairs(data.settings) do
        m.old_settings[k] = v
    end
end
m.data = data

-- 关键改动：将所有设置合并到一个 section 中，避免冲突
-- 所有选项都属于 /etc/config/tailscale 中的 `config settings 'settings'` 节
local s = m:section(TypedSection, "settings", nil) -- 主 section 不需要标题，因为我们会用 Tab
s.anonymous = true

-- 第 1 部分: Node Settings (即时生效)
-- 使用 Tab 来在视觉上进行分组
if data._profile_detail_data_raw then
    s:tab("node_settings", _("Node Settings"),
        _("These settings are applied instantly using the <code>tailscale set</code> command and do not require a service restart."))

    -- 使用 taboption 将选项添加到指定的 Tab 中
    o = s:taboption("node_settings", Flag, "accept_routes", _("Accept Routes")); o.default = data.settings.accept_routes and "1" or "0"; o.rmempty = false
    o = s:taboption("node_settings", Flag, "advertise_exit_node", _("Advertise as Exit Node")); o.default = data.settings.advertise_exit_node and "1" or "0"; o.rmempty = false
    o = s:taboption("node_settings", Value, "advertise_routes", _("Advertise Routes")); o.default = data.settings.advertise_routes; o.rmempty = true
    o = s:taboption("node_settings", Value, "exit_node", _("Use Exit Node")); o.default = data.settings.exit_node; o.rmempty = true
    o = s:taboption("node_settings", Flag, "exit_node_allow_lan_access", _("Allow LAN Access via Exit Node")); o.default = data.settings.exit_node_allow_lan_access and "1" or "0"; o.rmempty = false
    o = s:taboption("node_settings", Flag, "snat_subnet_routes", _("Enable SNAT for Subnet Routes")); o.default = data.settings.snat_subnet_routes and "1" or "0"; o.rmempty = false
    o = s:taboption("node_settings", Flag, "ssh", _("Enable SSH Server")); o.default = data.settings.ssh and "1" or "0"; o.rmempty = false
    o = s:taboption("node_settings", Flag, "shields_up", _("Shields Up Mode")); o.default = data.settings.shields_up and "1" or "0"; o.rmempty = false
    o = s:taboption("node_settings", Flag, "auto_update", _("Enable Auto-Updates")); o.default = data.settings.auto_update and "1" or "0"; o.rmempty = false
    o = s:taboption("node_settings", Value, "hostname", _("Custom Hostname")); o.default = data.settings.hostname; o.rmempty = true
else
    -- 这个错误信息部分是独立的，保持不变
    local s_err = m:section(TypedSection, "error", _("Settings Unavailable"))
    s_err.anonymous = true
    s_err.description = _("Node settings cannot be loaded. Please ensure Tailscale is running and properly configured.")
end

-- 第 2 部分: Daemon Environment Settings (需要重启)
-- 创建第二个 Tab
s:tab("daemon_settings", _("Daemon Environment Settings"),
    _("Changing these settings requires a <strong>service restart</strong> to take effect. This works by creating a script in <code>/etc/profile.d/</code> to set environment variables for the daemon."))

-- 将守护进程相关的选项添加到新的 Tab 中
o = s:taboption("daemon_settings", Value, "daemon_mtu", _("Set Custom MTU"), _("Leave empty for default. A common value for problematic networks is 1280."))
o.datatype = "uinteger"; o.placeholder = "1280"; o.default = data.settings.daemon_mtu

o = s:taboption("daemon_settings", Flag, "daemon_reduce_memory", _("Reduce Memory Usage"), _("Optimizes for lower memory consumption at the cost of higher CPU usage. Sets <code>GOCG=10</code> environment variable."))
o.default = data.settings.daemon_reduce_memory and "1" or "0"; o.rmempty = false


local env_script_path = "/etc/profile.d/tailscale-env.sh"
local env_script_content = [[#!/bin/sh

# This script is managed by luci-app-tailscale.
# It reads settings directly from /etc/config/tailscale and sets environment variables for tailscaled.

# Function to safely get a UCI value. Returns empty if not found.
uci_get_state() {
    uci get tailscale.settings."$1" 2>/dev/null
}

# Set GOGC for memory reduction if the option is '1'
if [ "$(uci_get_state daemon_reduce_memory)" = "1" ]; then
    export GOGC=10
fi

# Set custom MTU if the value is not empty
TS_MTU=$(uci_get_state daemon_mtu)
if [ -n "$TS_MTU" ]; then
    export TS_DEBUG_MTU="$TS_MTU"
fi
]]

function m.on_after_commit(self)
    -- 引入日志
    local log = function(...)
    local message = table.concat({...}, " ")
    sys.call("logger -t luci-tailscale " .. util.shellquote(message))
    end
    log("on_after_commit triggered.")

    -- 1. 处理 Daemon Environment Settings
    
    -- 从提交的表单中获取新值
    local new_mtu = self:formvalue("settings", "daemon_mtu") or ""
    local new_reduce_mem = self:formvalue("settings", "daemon_reduce_memory") or "0"
    log(string.format("New form values: daemon_mtu='%s', daemon_reduce_memory='%s'", new_mtu, new_reduce_mem))
    
    local old_mtu = self.old_settings.daemon_mtu or ""
    local old_reduce_mem = (self.old_settings.daemon_reduce_memory == "1" or self.old_settings.daemon_reduce_memory == true) and "1" or "0"
    log(string.format("Old settings values (from self.old_settings): daemon_mtu='%s', daemon_reduce_memory='%s'", old_mtu, old_reduce_mem))

    -- 检查守护进程相关的设置是否有变化
    local daemon_settings_changed = (new_mtu ~= old_mtu) or (new_reduce_mem ~= old_reduce_mem)
    log("Daemon settings changed:", tostring(daemon_settings_changed))

    if daemon_settings_changed then
        -- 判断是否需要创建脚本（即，至少有一个守护进程设置是启用的）
        local script_needed = (new_mtu ~= "") or (new_reduce_mem == "1")
        log("Script needed:", tostring(script_needed))

        if script_needed  or true then -- 有bug懒得改了，md找了两个小时没找到哪里
            -- 写入固定的脚本内容并设置权限
            log("Writing env script to", env_script_path)
            fs.writefile(env_script_path, env_script_content)
            sys.call("chmod +x " .. env_script_path)
        else
            -- 如果不再需要脚本，则删除它（如果存在）
            if fs.access(env_script_path) then
                log("Removing env script from", env_script_path)
                fs.remove(env_script_path)
            else
                log("Env script not found, nothing to remove.")
            end
        end
        
        m.message = _("Daemon settings applied. Restarting Tailscale service...")
        log("Committing UCI and restarting tailscale service.")
        -- 提交 UCI 更改并重启服务
        sys.call("uci commit tailscale && /etc/init.d/tailscale restart >/dev/null 2>&1 &")
        return 
    end

    -- 2. 处理 Node Settings
    if data._profile_detail_data_raw then
        local changed = false
        local form = {}
        local node_setting_keys = {
            "accept_routes", "advertise_exit_node", "advertise_routes",
            "exit_node", "exit_node_allow_lan_access", "snat_subnet_routes",
            "ssh", "shields_up", "auto_update", "hostname"
        }

        for _, key in ipairs(node_setting_keys) do
            local new_val_str = self:formvalue("settings", key)
            if new_val_str ~= nil then
                form[key] = new_val_str
                -- 从原始加载的 'data' 变量中获取旧值进行比较
                local old_val = data.settings[key]
                local old_val_str
                
                if type(old_val) == "boolean" then
                    old_val_str = old_val and "1" or "0"
                else
                    old_val_str = tostring(old_val or "")
                end

                if new_val_str ~= old_val_str then
                    changed = true
                end
            end
        end

        if changed then
            local args = {}
            local function add_arg(k, v, is_bool) 
                if is_bool then 
                    table.insert(args, string.format("--%s=%s", k, v and "true" or "false")) 
                else 
                    table.insert(args, string.format("--%s=%s", k, util.shellquote(v or ""))) 
                end 
            end
            add_arg("accept-routes", form.accept_routes == "1", true)
            add_arg("advertise-exit-node", form.advertise_exit_node == "1", true)
            add_arg("exit-node-allow-lan-access", form.exit_node_allow_lan_access == "1", true)
            add_arg("snat-subnet-routes", form.snat_subnet_routes == "1", true)
            add_arg("ssh", form.ssh == "1", true)
            add_arg("shields-up", form.shields_up == "1", true)
            add_arg("auto-update", form.auto_update == "1", true)
            add_arg("advertise-routes", form.advertise_routes, false)
            add_arg("exit-node", form.exit_node, false)
            add_arg("hostname", form.hostname, false)

            sys.call("tailscale set " .. table.concat(args, " ") .. " >/dev/null 2>&1")
            sys.call("sleep 1")
            m.message = _("Node settings applied.")
        end
    end
end

return m