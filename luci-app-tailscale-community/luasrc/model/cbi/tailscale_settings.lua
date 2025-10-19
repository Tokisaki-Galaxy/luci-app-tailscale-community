local util = require "luci.util"
local sys = require "luci.sys"
local nixio = require "nixio"
local fs = require "nixio.fs"
local data_loader = require "luci.model.tailscale_data"
local i18n = require "luci.i18n"
_ = i18n.translate

-- 加载所有数据
local data = data_loader.load()

m = Map("tailscale", "Tailscale")
m:chain("luci")

m.data = data
-- Node Settings (即时生效)
if data._profile_detail_data_raw then
    s_set = m:section(TypedSection, "settings", _("Node Settings"),
        _("These settings are applied instantly using the <code>tailscale set</code> command and do not require a service restart."))
    s_set.anonymous = true

    o = s_set:option(Flag, "accept_routes", _("Accept Routes")); o.default = data.settings.accept_routes and "1" or "0"; o.rmempty = false
    o = s_set:option(Flag, "advertise_exit_node", _("Advertise as Exit Node")); o.default = data.settings.advertise_exit_node and "1" or "0"; o.rmempty = false
    o = s_set:option(Value, "advertise_routes", _("Advertise Routes")); o.default = data.settings.advertise_routes; o.rmempty = true
    o = s_set:option(Value, "exit_node", _("Use Exit Node")); o.default = data.settings.exit_node; o.rmempty = true
    o = s_set:option(Flag, "exit_node_allow_lan_access", _("Allow LAN Access via Exit Node")); o.default = data.settings.exit_node_allow_lan_access and "1" or "0"; o.rmempty = false
    o = s_set:option(Flag, "snat_subnet_routes", _("Enable SNAT for Subnet Routes")); o.default = data.settings.snat_subnet_routes and "1" or "0"; o.rmempty = false
    o = s_set:option(Flag, "ssh", _("Enable SSH Server")); o.default = data.settings.ssh and "1" or "0"; o.rmempty = false
    o = s_set:option(Flag, "shields_up", _("Shields Up Mode")); o.default = data.settings.shields_up and "1" or "0"; o.rmempty = false
    o = s_set:option(Flag, "auto_update", _("Enable Auto-Updates")); o.default = data.settings.auto_update and "1" or "0"; o.rmempty = false
    o = s_set:option(Value, "hostname", _("Custom Hostname")); o.default = data.settings.hostname; o.rmempty = true
else
    s_err = m:section(TypedSection, "error", _("Settings Unavailable"))
    s_err.anonymous = true
    s_err.description = _("Node settings cannot be loaded. Please ensure Tailscale is running and properly configured.")
end

-- Daemon Environment Settings (需要重启)
s_daemon = m:section(TypedSection, "settings", _("Daemon Environment Settings"),
    _("Changing these settings requires a <strong>service restart</strong> to take effect. This works by creating a script in <code>/etc/profile.d/</code> to set environment variables for the daemon."))
s_daemon.anonymous = true

o = s_daemon:option(Value, "daemon_mtu", _("Set Custom MTU"), _("Leave empty for default. A common value for problematic networks is 1280."))
o.datatype = "uinteger"; o.placeholder = "1280"; o.default = data.settings.daemon_mtu

o = s_daemon:option(Flag, "daemon_reduce_memory", _("Reduce Memory Usage"), _("Optimizes for lower memory consumption at the cost of higher CPU usage. Sets <code>GOCG=10</code> environment variable."))
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


-- ## 核心修改：重构 on_after_commit 函数 ##
function m.on_after_commit(self)
    -- 1. 处理 Daemon Environment Settings
    
    -- 从提交的表单中获取新值，并进行规范化处理
    local new_mtu = self:formvalue("settings", "daemon_mtu") or ""
    local new_reduce_mem = self:formvalue("settings", "daemon_reduce_memory") or "0"
    
    -- 从 commit 前缓存的数据中获取旧值，并进行同样的规范化处理
    local old_mtu = self.data.settings.daemon_mtu or ""
    local old_reduce_mem = (self.data.settings.daemon_reduce_memory == "1" or self.data.settings.daemon_reduce_memory == true) and "1" or "0"

    -- 检查守护进程相关的设置是否有变化
    local daemon_settings_changed = (new_mtu ~= old_mtu) or (new_reduce_mem ~= old_reduce_mem)

    if daemon_settings_changed then
        -- 判断是否需要创建脚本（即，至少有一个守护进程设置是启用的）
        local script_needed = (new_mtu ~= "") or (new_reduce_mem == "1")

        if script_needed then
            -- 写入固定的脚本内容并设置权限
            fs.writefile(env_script_path, env_script_content)
            sys.call("chmod +x " .. env_script_path)
        else
            -- 如果不再需要脚本，则删除它（如果存在）
            if fs.access(env_script_path) then
                fs.remove(env_script_path)
            end
        end
        
        m.message = _("Daemon settings applied. Restarting Tailscale service...")
        -- 提交 UCI 更改并重启服务
        sys.call("uci commit tailscale && /etc/init.d/tailscale restart >/dev/null 2>&1 &")
        return 
    end

    -- 2. 处理 Node Settings
    if self.data._profile_detail_data_raw then
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
                local old_val = self.data.settings[key]
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