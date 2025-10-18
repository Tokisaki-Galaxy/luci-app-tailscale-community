local util = require "luci.util"
local data_loader = require "luci.model.tailscale_data"

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
o.value = data.ipv4

o = s:option(DummyValue, "_ipv6", _("Tailscale IPv6"))
o.value = data.ipv6 or _("N/A")

o = s:option(DummyValue, "_domain", _("Tailnet Name"))
o.value = data.domain_name

-- ## Peer Status Table Section ##
if data.peers then
    s_peers = m:section(Table, "peers", _("Network Devices"))
    s_peers.anonymous = true
    s_peers.sortable = false

    s_peers:option(DummyValue, "online", _("Status")).rawhtml = true
    s_peers:option(DummyValue, "hostname", _("Hostname")).rawhtml = true
    s_peers:option(DummyValue, "ips", _("Tailscale IPs")).rawhtml = true
    s_peers:option(DummyValue, "os", _("OS")).rawhtml = true
    s_peers:option(DummyValue, "connection", _("Connection"))
    s_peers:option(DummyValue, "lastseen", _("Last Seen"))

    local function format_last_seen(timestr)
        if not timestr or timestr:match("^0001") then return _("Never") end
        local y, M, d, h, m = timestr:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
        if y then return string.format("%s-%s-%s %s:%s", y, M, d, h, m) end
        return timestr
    end

    for _, peer in ipairs(data.peers) do
        local row_id = peer.PublicKey
        s_peers:get(row_id, "online", peer.Online and '<span style="color:green;">●</span>' or '<span style="color:gray;">○</span>')
        s_peers:get(row_id, "hostname", string.format("<strong>%s</strong><br /><small>%s</small>", util.pcdata(peer.HostName), util.pcdata(peer.DNSName)))
        s_peers:get(row_id, "ips", table.concat(peer.TailscaleIPs or {}, "<br />"))
        s_peers:get(row_id, "os", util.pcdata(peer.OS))
        local conn_type = _("N/A")
        if peer.Online then conn_type = peer.Relay and peer.Relay ~= "" and ("Relay (%s)"):format(peer.Relay) or _("Direct") end
        s_peers:get(row_id, "connection", conn_type)
        s_peers:get(row_id, "lastseen", peer.Online and _("Now") or format_last_seen(peer.LastSeen))
    end
end

return m