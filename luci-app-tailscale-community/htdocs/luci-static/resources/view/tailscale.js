'use strict';
'require view';
'require form';
'require rpc';
'require ui';

// 定义 RPC 调用
var callIsInstalled = rpc.declare({
    object: 'tailscale',
    method: 'is_installed'
});

var callGetStatus = rpc.declare({
    object: 'tailscale',
    method: 'get_status'
});

var callGetSettings = rpc.declare({
    object: 'tailscale',
    method: 'get_settings'
});

var callSetSettings = rpc.declare({
    object: 'tailscale',
    method: 'set_settings',
    params: ['form_data']
});


// 主视图
return view.extend({
    // load 函数在 render 之前执行，用于预加载数据
    load: function() {
        return Promise.all([
            callIsInstalled(),
            callGetStatus(),
            callGetSettings()
        ]);
    },

    // render 函数负责渲染页面内容
    render: function(data) {
        var is_installed = data[0];
        var status = data[1];
        var settings = data[2];

        // 如果 tailscale 未安装，显示提示信息
        if (!is_installed) {
            return E('div', {}, [
                E('h2', {}, _('Tailscale')),
                E('p', {}, _('Tailscale executable not found. Please install tailscale first.'))
            ]);
        }

        var m, s, o;

        m = new form.Map('tailscale', _('Tailscale'), 
            _('This page allows you to control Tailscale, a zero-config mesh VPN.'));

        // 使用标签页来组织状态和设置
        var tabs = m.section(form.TypedSection, 'global', null);
        tabs.tabbed = true;

        /* --- Status Tab --- */
        var statusTab = tabs.tab('status', _('Status'));

        s = statusTab.section(form.NamedSection, 'status_info', 'status', _('Service Status'));
        o = s.option(form.DummyValue, '_status', _('Service Status'));
        o.rawhtml = true;
        o.value = status.running
            ? `<span style="color:green;">${_("Running")}</span>`
            : `<span style="color:red;">${_("Not Running")}</span>`;

        o = s.option(form.DummyValue, '_ipv4', _('Tailscale IPv4'));
        o.value = status.ipv4;
        
        o = s.option(form.DummyValue, '_ipv6', _('Tailscale IPv6'));
        o.value = status.ipv6 || 'N/A';
        
        o = s.option(form.DummyValue, '_domain', _('Tailnet Name'));
        o.value = status.domain_name;


        // Peer status table
        s = statusTab.section(form.Table, status.peers, _('Network Devices'));
        s.anonymous = true;
        s.sortable = false;

        o = s.option(form.DummyValue, 'Online', _('Status'));
        o.rawhtml = true;
        o.center = true;
        o.value = function(section_id) {
            var peer = status.peers.find(p => p.ID === section_id);
            return peer.Online
                ? '<span style="color:green;" title="Online">●</span>'
                : '<span style="color:gray;" title="Offline">○</span>';
        };

        o = s.option(form.DummyValue, 'HostName', _('Hostname'));
        o.rawhtml = true;
        o.value = function(section_id) {
            var peer = status.peers.find(p => p.ID === section_id);
            return `<strong>${L.escapeHTML(peer.HostName)}</strong><br /><small>${L.escapeHTML(peer.DNSName)}</small>`;
        };

        o = s.option(form.DummyValue, 'TailscaleIPs', _('Tailscale IPs'));
        o.rawhtml = true;
        o.value = function(section_id) {
            var peer = status.peers.find(p => p.ID === section_id);
            return (peer.TailscaleIPs || []).join('<br />');
        };

        o = s.option(form.DummyValue, 'OS', _('OS'));
        o.value = function(section_id) {
            var peer = status.peers.find(p => p.ID === section_id);
            return L.escapeHTML(peer.OS);
        };
        
        o = s.option(form.DummyValue, 'ConnectionInfo', _('Connection'));
        o.rawhtml = true;
        o.value = function(section_id) {
            var peer = status.peers.find(p => p.ID === section_id);
            if (!peer.Online) return _("N/A");
            var conn_info = peer.ConnectionInfo || "-";
            if (conn_info.includes("direct")) {
                return `<span style="color:green;" title="${L.escapeHTML(conn_info)}">${_("Direct")}</span>`;
            } else if (conn_info.includes("relay")) {
                var match = conn_info.match(/\(([^)]+)\)/);
                var relay_node = match ? ` (${match[1]})` : '';
                return `<span style="color:orange;" title="${L.escapeHTML(conn_info)}">${_("Relay")}${relay_node}</span>`;
            }
            return L.escapeHTML(conn_info);
        };

        o = s.option(form.DummyValue, 'LastSeen', _('Last Seen'));
        o.value = function(section_id) {
            var peer = status.peers.find(p => p.ID === section_id);
            if (peer.Online) return _("Now");
            if (!peer.LastSeen || peer.LastSeen.startsWith("0001")) return _("Never");
            return peer.LastSeen.replace('T', ' ').substring(0, 16);
        };
        
        s.section_id = function(section_id) {
            return status.peers[section_id].ID;
        };


        /* --- Settings Tab --- */
        var settingsTab = tabs.tab('settings', _('Settings'));

        s = settingsTab.section(form.TypedSection, 'settings', null);
        s.anonymous = true;

        var settingsTabs = s.tab('node_settings', _('Node Settings'), _('These settings are applied instantly using the <code>tailscale set</code> command.'));

        o = settingsTabs.option(form.Flag, 'accept_routes', _('Accept Routes'));
        o.default = settings.accept_routes ? '1' : '0';

        o = settingsTabs.option(form.Flag, 'advertise_exit_node', _('Advertise as Exit Node'));
        o.default = settings.advertise_exit_node ? '1' : '0';

        o = settingsTabs.option(form.Value, 'advertise_routes', _('Advertise Routes'), _('Comma-separated list of CIDRs'));
        o.default = settings.advertise_routes;
        
        o = settingsTabs.option(form.Value, 'exit_node', _('Use Exit Node'), _('IP or name of the exit node. Leave empty to disable.'));
        o.default = settings.exit_node;

        o = settingsTabs.option(form.Flag, 'exit_node_allow_lan_access', _('Allow LAN Access via Exit Node'));
        o.default = settings.exit_node_allow_lan_access ? '1' : '0';
        
        o = settingsTabs.option(form.Flag, 'snat_subnet_routes', _('Enable SNAT for Subnet Routes'));
        o.default = settings.snat_subnet_routes ? '1' : '0';

        o = settingsTabs.option(form.Flag, 'ssh', _('Enable SSH Server'));
        o.default = settings.ssh ? '1' : '0';

        o = settingsTabs.option(form.Flag, 'shields_up', _('Shields Up Mode'));
        o.default = settings.shields_up ? '1' : '0';

        o = settingsTabs.option(form.Flag, 'auto_update', _('Enable Auto-Updates'));
        o.default = settings.auto_update ? '1' : '0';

        o = settingsTabs.option(form.Value, 'hostname', _('Custom Hostname'));
        o.default = settings.hostname;

        
        var daemonTabs = s.tab('daemon_settings', _('Daemon Environment Settings'), _('Changing these settings requires a service restart.'));
        
        o = daemonTabs.option(form.Value, 'daemon_mtu', _('Set Custom MTU'));
        o.datatype = 'uinteger';
        o.placeholder = '1280';
        o.default = settings.daemon_mtu;

        o = daemonTabs.option(form.Flag, 'daemon_reduce_memory', _('Reduce Memory Usage'), _('Sets <code>GOCG=10</code> environment variable.'));
        o.default = settings.daemon_reduce_memory === '1' ? '1' : '0';


        return m.render();
    },

    // handleSaveApply 函数在点击 "Save & Apply" 后执行
    handleSaveApply: function(ev) {
        var map = this.map;
        return map.save().then(function() {
            var data = map.data.get('tailscale', 'settings');
            ui.showModal(_('Applying changes...'), E('em', {}, _('Please wait.')));
            
            callSetSettings(data).then(function(response) {
                if (response.success) {
                    ui.hideModal();
                    ui.addNotification(null, E('p', _('Tailscale settings applied successfully.')), 'info');
                    // 重新加载页面以显示最新状态
                    setTimeout(function() { window.location.reload(); }, 2000);
                } else {
                    ui.addNotification(null, E('p', _('Error applying settings: %s').format(response.error)), 'error');
                }
            });
        });
    },

    handleSave: null,
    handleReset: null
});