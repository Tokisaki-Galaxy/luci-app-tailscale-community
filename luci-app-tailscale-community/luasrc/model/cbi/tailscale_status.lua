local util = require "luci.util"
local data_loader = require "luci.model.tailscale_data"
local i18n = require "luci.i18n"
_ = i18n.translate

-- 加载所有数据
local data = data_loader.load()

m = Map("tailscale", "Tailscale")

-- ## Status Display Section ##
s = m:section(TypedSection, "tailscale_status", _("Status"))
s.anonymous = true

o = s:option(DummyValue, "_status", _("Service Status"))
o.value = data.running and ('<span style="color:green;">' .. _("Running") .. '</span>') or ('<span style="color:red;">' .. _("Not Running") .. '</span>')
o.rawhtml = true

o = s:option(DummyValue, "_ipv4", _("Tailscale IPv4"))
o.value = _(data.ipv4)

o = s:option(DummyValue, "_ipv6", _("Tailscale IPv6"))
o.value = data.ipv6 or _("N/A")

o = s:option(DummyValue, "_domain", _("Tailnet Name"))
o.value = _(data.domain_name)

-- ## Peer Status Table Section ##
if data.peers then
    s_peers = m:section(Table, "peers", _("Network Devices"))
    s_peers.anonymous = true
    s_peers.sortable = false

    local online_col = s_peers:option(DummyValue, "online", _("Status"))
    online_col.rawhtml = true

    local hostname_col = s_peers:option(DummyValue, "hostname", _("Hostname"))
    hostname_col.rawhtml = true

    local ips_col = s_peers:option(DummyValue, "ips", _("Tailscale IPs"))
    ips_col.rawhtml = true

    local os_col = s_peers:option(DummyValue, "os", _("OS"))
    os_col.rawhtml = true

    local connection_col = s_peers:option(DummyValue, "connection", _("Connection"))
    connection_col.rawhtml = true -- 允许HTML

    local lastseen_col = s_peers:option(DummyValue, "lastseen", _("Last Seen"))


    local function format_last_seen(timestr)
        if not timestr or timestr:match("^0001") then return _("Never") end
        local y, M, d, h, m = timestr:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
        if y then return string.format("%s-%s-%s %s:%s", y, M, d, h, m) end
        return timestr
    end

    online_col.value = function(self, section, value)
        local peer = data.peers[tonumber(section)]
        return peer.Online and
            '<span style="color:green;" title="'.._("Online")..'">●</span>' or
            '<span style="color:gray;" title="'.._("Offline")..'">○</span>'
    end

    hostname_col.value = function(self, section, value)
        local peer = data.peers[tonumber(section)]
        return string.format("<strong>%s</strong><br /><small>%s</small>", util.pcdata(peer.HostName), util.pcdata(peer.DNSName))
    end

    ips_col.value = function(self, section, value)
        local peer = data.peers[tonumber(section)]
        return table.concat(peer.TailscaleIPs or {}, "<br />")
    end

    os_col.value = function(self, section, value)
        local peer = data.peers[tonumber(section)]
        return util.pcdata(peer.OS)
    end

    connection_col.value = function(self, section, value)
        local peer = data.peers[tonumber(section)]
        if not peer.Online then
            return _("N/A")
        end

        local conn_info = peer.ConnectionInfo or "-"

        -- 根据关键字美化显示
        if conn_info:match("direct") then
            return ('<span style="color:green;" title="%s">%s</span>'):format(util.pcdata(conn_info), _("Direct"))
        elseif conn_info:match("relay") then
            -- 提取 relay 节点名称
            local relay_node = conn_info:match("%((%S+)%)")
            local display_text = relay_node and ("Relay (%s)"):format(relay_node) or _("Relay")
            return ('<span style="color:orange;" title="%s">%s</span>'):format(util.pcdata(conn_info), display_text)
        elseif conn_info == "-" then
            return _("This device")
        elseif conn_info:match("^idle") then
            return ('<span style="color:blue;" title="%s">%s</span>'):format(util.pcdata(conn_info), _("Idle"))
        else
            -- 其他状态 (如 active, offers exit node) 直接显示
            return util.pcdata(conn_info)
        end
    end

    lastseen_col.value = function(self, section, value)
        local peer = data.peers[tonumber(section)]
        return peer.Online and _("Now") or format_last_seen(peer.LastSeen)
    end

    function s_peers.cfgsections(self)
        local sections = {}
        for i = 1, #data.peers do
            sections[#sections+1] = tostring(i)
        end
        return sections
    end
end

return m