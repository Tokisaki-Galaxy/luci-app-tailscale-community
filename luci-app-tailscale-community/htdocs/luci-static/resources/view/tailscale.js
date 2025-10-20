'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require uci';
'require tools.widgets as widgets';

var callIsInstalled = rpc.declare({ object: 'tailscale', method: 'is_installed' });
var callGetStatus = rpc.declare({ object: 'tailscale', method: 'get_status' });
var callGetSettings = rpc.declare({ object: 'tailscale', method: 'get_settings' });
var callSetSettings = rpc.declare({ object: 'tailscale', method: 'set_settings', params: ['form_data'] });

var startupConf = [[form.Flag, 'stdout', _('Log stdout')],
[form.Flag, 'stderr', _('Log stderr')],
[widgets.UserSelect, 'user', _('Run daemon as user')], [widgets.GroupSelect, 'group', _('Run daemon as group')],
[form.DynamicList, 'env', _('Environment variable'), _('OS environments pass to frp for config file template, see <a href="https://github.com/fatedier/frp#configuration-file-template">frp README</a>'), { placeholder: 'ENV_NAME=value' }],];

var commonConf = [[form.Value, 'server_addr', _('Server address'), _('ServerAddr specifies the address of the server to connect to.<br />By default, this value is "127.0.0.1".'), { datatype: 'host' }],
[form.Value, 'server_port', _('Server port'), _('ServerPort specifies the port to connect to the server on.<br />By default, this value is 7000.'), { datatype: 'port' }],
[form.Value, 'log_file', _('Log file'), _('LogFile specifies a file where logs will be written to. This value will only be used if LogWay is set appropriately.<br />By default, this value is "console".')],];

function setParams(o, params) {
    if (!params) return; for (var key in params) {
        var val = params[key]; if (key === 'values') {
            for (var j = 0; j < val.length; j++) {
                var args = val[j]; if (!Array.isArray(args))
                    args = [args]; o.value.apply(o, args);
            }
        } else if (key === 'depends') {
            if (!Array.isArray(val))
                val = [val]; var deps = []; for (var j = 0; j < val.length; j++) {
                    var d = {}; for (var vkey in val[j])
                        d[vkey] = val[j][vkey]; for (var k = 0; k < o.deps.length; k++) { for (var dkey in o.deps[k]) { d[dkey] = o.deps[k][dkey]; } }
                    deps.push(d);
                }
            o.deps = deps;
        } else { o[key] = params[key]; }
    }
    if (params['datatype'] === 'bool') { o.enabled = 'true'; o.disabled = 'false'; }
}
function defTabOpts(s, t, opts, params) { for (var i = 0; i < opts.length; i++) { var opt = opts[i]; var o = s.taboption(t, opt[0], opt[1], opt[2], opt[3]); setParams(o, opt[4]); setParams(o, params); } }
function defOpts(s, opts, params) { for (var i = 0; i < opts.length; i++) { var opt = opts[i]; var o = s.option(opt[0], opt[1], opt[2], opt[3]); setParams(o, opt[4]); setParams(o, params); } }
const callServiceList = rpc.declare({ object: 'service', method: 'list', params: ['name'], expect: { '': {} } });

function getRunningStatus() {
    return L.resolveDefault(callGetStatus(), { running: false }).then(function (res) {
        return res;
    });
}

function renderStatus(status) {
    // 如果 status 对象为空或没有 running 属性，则显示加载中
    if (!status || !status.hasOwnProperty('running')) {
        return _('Collecting data ...');
    }

    var finalHtml = [];

    // --- Part 1: 渲染水平状态表格 ---
    if (!status.running) {
        finalHtml.push('<dl class="cbi-value"><dt>' + _('Service Status') + '</dt>');
        finalHtml.push('<dd><span style="color:red;"><strong>' + _('NOT RUNNING') + '</strong></span></dd></dl>');
        return finalHtml.join('');
    }
    
    var labels = [];
    var values = [];
    labels.push('<strong>' + _('Service Status') + '</strong>');
    values.push('<span style="color:green;"><strong>' + _('RUNNING') + '</strong></span>');
    labels.push('<strong>' + _('Version') + '</strong>');
    values.push(status.version || 'N/A');
    labels.push('<strong>' + _('TUN Mode') + '</strong>');
    values.push(status.TUNMode ? _('Enabled') : _('Disabled'));
    labels.push('<strong>' + _('Tailscale IPv4') + '</strong>');
    values.push(status.ipv4 || 'N/A');
    labels.push('<strong>' + _('Tailscale IPv6') + '</strong>');
    values.push(status.ipv6 || 'N/A');
    labels.push('<strong>' + _('Tailnet Name') + '</strong>');
    values.push(status.domain_name || 'N/A');

    var statusTable = '<table style="width: 100%; border-spacing: 0 5px;">';
    statusTable += '<tr>';
    for (var i = 0; i < labels.length; i++) {
        statusTable += '<td style="padding-right: 20px;">' + labels[i] + '</td>';
    }
    statusTable += '</tr><tr>';
    for (var i = 0; i < values.length; i++) {
        statusTable += '<td style="padding-right: 20px;">' + values[i] + '</td>';
    }
    statusTable += '</tr></table>';
    finalHtml.push(statusTable);


    // --- Part 2: 渲染 Peers 设备表格 ---
    finalHtml.push('<div style="margin-top: 25px;">');
    finalHtml.push('<h4>' + _('Network Devices') + '</h4>');

    var peers = status.peers;
    if (!peers || Object.keys(peers).length === 0) {
        finalHtml.push('<p>' + _('No peer devices found.') + '</p>');
    } else {
        var peersTable = '<table class="cbi-table">';
        peersTable += '<tr class="cbi-table-header">';
        var th_style = 'padding-right: 20px; text-align: left;';
        peersTable += '<th class="cbi-table-cell" style="' + th_style + 'width: 80px;">' + _('Status') + '</th>';
        peersTable += '<th class="cbi-table-cell" style="' + th_style + '">' + _('Hostname') + '</th>';
        peersTable += '<th class="cbi-table-cell" style="' + th_style + '">' + _('Tailscale IP') + '</th>';
        peersTable += '<th class="cbi-table-cell" style="' + th_style + '">' + _('OS') + '</th>';
        peersTable += '<th class="cbi-table-cell" style="' + th_style + '">' + _('Connection Info') + '</th>';
        peersTable += '</tr>';

        for (var hostname in peers) {
            if (peers.hasOwnProperty(hostname)) {
                var peer = peers[hostname];
                peersTable += '<tr class="cbi-rowstyle-1">';
                var status_indicator = (peer.status === 'active')
                    ? '<span style="color:green;" title="' + _("Online") + '">●</span>'
                    : '<span style="color:gray;" title="' + _("Offline") + '">○</span>';
                var td_style = 'padding-right: 20px;';
                peersTable += '<td class="cbi-value-field" style="' + td_style + '">' + status_indicator + '</td>';
                peersTable += '<td class="cbi-value-field" style="' + td_style + '"><strong>' + hostname + '</strong></td>';
                peersTable += '<td class="cbi-value-field" style="' + td_style + '">' + (peer.ip || 'N/A') + '</td>';
                peersTable += '<td class="cbi-value-field" style="' + td_style + '">' + (peer.ostype || 'N/A') + '</td>';
                peersTable += '<td class="cbi-value-field" style="' + td_style + '">' + (peer.linkadress || '-') + '</td>';
                peersTable += '</tr>';
            }
        }
        peersTable += '</table>';
        finalHtml.push(peersTable);
    }

    finalHtml.push('</div>');

    return finalHtml.join('');
}

return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(callIsInstalled(), { installed: false }),
            L.resolveDefault(callGetStatus(), { running: false, peers: [] }),
            L.resolveDefault(callGetSettings(), { accept_routes: false })
        ])
        .then(function(rpc_data) {
            // rpc_data 是一个数组: [status_result, settings_result]
            var settings_from_rpc = rpc_data[1];

            return uci.load('tailscale').then(function() {
                if (uci.get('tailscale', 'settings') === null) {
                    uci.add('tailscale', 'settings', 'settings');

                    //uci.set('tailscale', 'settings', 'accept_routes', settings_from_rpc.accept_routes);
                    //uci.set('tailscale', 'settings', 'advertise_exit_node', settings_from_rpc.advertise_exit_node);
                    //uci.set('tailscale', 'settings', 'advertise_routes', settings_from_rpc.advertise_routes);
                    uci.set('tailscale', 'settings', 'accept_routes', '0');
                    uci.set('tailscale', 'settings', 'advertise_exit_node', '0');
                    uci.set('tailscale', 'settings', 'advertise_routes', '0');
                    uci.set('tailscale', 'settings', 'exit_node_allow_lan_access', '0');
                    uci.set('tailscale', 'settings', 'snat_subnet_routes', '0');
                    uci.set('tailscale', 'settings', 'ssh', '0');
                    uci.set('tailscale', 'settings', 'shields_up', '0');
                    uci.set('tailscale', 'settings', 'daemon_reduce_memory', '0');
                    uci.set('tailscale', 'settings', 'daemon_mtu', '');
                    return uci.save();
                }
            }).then(function() {
                return rpc_data;
            });
        });
    },

    render: function (data) {
        var status = data[0] || {};
        var settings = data[1] || {};
        
        var m, s, o;
        m = new form.Map('frpc', _('Tailscale'), _('Tailscale is a mesh VPN solution that makes it easy to connect your devices securely. This configuration page allows you to manage Tailscale settings on your OpenWrt device.'));
        
        s = m.section(form.NamedSection, '_status');
        s.anonymous = true;
        s.render = function (section_id) {
            L.Poll.add(
                function () {
                    return getRunningStatus().then(function (res) {
                        var view = document.getElementById("service_status_display");
                        if (view) {
                            // renderStatus 现在处理完整的对象并返回 HTML
                            view.innerHTML = renderStatus(res);
                        }
                    });
                }, 10);

            // 初始的容器，ID 用于被轮询更新
            return E('div', { 'id': 'service_status_display', 'class': 'cbi-value' }, 
                _('Collecting data ...')
            );
        }

        s = m.section(form.NamedSection, 'common', 'conf');
        s.dynamic = true;

        s.tab('common', _('Common Settings'));
        defTabOpts(s, 'common', commonConf, { optional: true });
        
        s.tab('init', _('Startup Settings'));
        o = s.taboption('init', form.SectionValue, 'init', form.TypedSection, 'init', _('Startup Settings'));
        s = o.subsection;
        s.anonymous = true;
        s.dynamic = false;
        defOpts(s, startupConf);

        return m.render();
    },

    // handleSaveApply 函数在点击 "Save & Apply" 后执行
    handleSaveApply: function (ev) {
        var map = this.map;
        return map.save().then(function () {
            var data = map.data.get('tailscale', 'settings');
            ui.showModal(_('Applying changes...'), E('em', {}, _('Please wait.')));

            callSetSettings(data).then(function (response) {
                if (response.success) {
                    ui.hideModal();
                    ui.addNotification(null, E('p', _('Tailscale settings applied successfully.')), 'info');
                    // 重新加载页面以显示最新状态
                    setTimeout(function () { window.location.reload(); }, 2000);
                } else {
                    ui.addNotification(null, E('p', _('Error applying settings: %s').format(response.error)), 'error');
                }
            });
        });
    },

    handleSave: null,
    handleReset: null
});