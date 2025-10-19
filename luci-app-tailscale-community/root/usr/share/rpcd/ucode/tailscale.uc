'use strict';
'require rpc';
'require uci';
'require fs';
'require util';
'require ubase64';

var tailscale = rpc.service("tailscale");

tailscale.is_installed = function() {
    return fs.access('/usr/sbin/tailscale') || fs.access('/usr/bin/tailscale');
};

// 获取所有状态信息
tailscale.get_status = function() {
    let data = {
        running: false,
        ipv4: "Not running",
        ipv6: null,
        domain_name: "Unknown",
        peers: []
    };

    // 1. 检查运行状态和 IP
    let ip_output = fs.exec('tailscale', ['ip']);
    if (ip_output.code === 0 && ip_output.stdout) {
        data.running = true;
        let lines = ip_output.stdout.trim().split('\n');
        data.ipv4 = lines[0] || "N/A";
        if (lines.length > 1) {
            data.ipv6 = lines[1];
        }
    }

    // 2. 获取 peers 列表 (JSON)
    let status_json_output = fs.exec('tailscale', ['status', '--json']);
    let peer_map = {};
    if (status_json_output.code === 0 && status_json_output.stdout) {
        try {
            let status_data = JSON.parse(status_json_output.stdout);
            if (status_data.Peer) {
                for (let key in status_data.Peer) {
                    let peer = status_data.Peer[key];
                    peer_map[peer.TailscaleIPs[0]] = peer; // 使用第一个IP作为key
                }
            }
        } catch (e) { /* ignore parse error */ }
    }

    // 3. 获取 peers 的连接详情 (plain text)
    let status_plain_output = fs.exec('tailscale', ['status']);
    if (status_plain_output.code === 0 && status_plain_output.stdout) {
        status_plain_output.stdout.trim().split('\n').forEach(line => {
            let parts = line.trim().split(/\s+/);
            if (parts.length >= 5) {
                let ip = parts[0];
                if (peer_map[ip]) {
                    // 合并连接信息
                    peer_map[ip].ConnectionInfo = parts.slice(4).join(' ');
                }
            }
        });
    }

    // 转换为数组并排序
    for (let key in peer_map) {
        data.peers.push(peer_map[key]);
    }
    data.peers.sort((a, b) => a.HostName.localeCompare(b.HostName));
    
    // 4. 读取 state file 获取 domain name
    // 注意：为了简化，这里只解析域名，完整的运行时设置解析可以后续添加
    uci.load('tailscale');
    let state_file_path = uci.get('tailscale', 'settings', 'state_file') || "/etc/tailscale/tailscaled.state";
    if (fs.access(state_file_path)) {
        try {
            let state_data = JSON.parse(fs.readfile(state_file_path));
            if (state_data && state_data._profiles) {
                let profiles_json = ubase64.decode(state_data._profiles);
                let profiles_data = JSON.parse(profiles_json);
                for (let key in profiles_data) {
                    if (profiles_data[key].NetworkProfile && profiles_data[key].NetworkProfile.DomainName) {
                        data.domain_name = profiles_data[key].NetworkProfile.DomainName;
                        break;
                    }
                }
            }
        } catch (e) { /* ignore parse error */ }
    }

    return data;
};

// 获取配置信息 (包括 UCI 和运行时配置)
tailscale.get_settings = function() {
    let settings = {};
    
    // 1. 从 UCI 加载用户保存的配置
    uci.load('tailscale');
    let uci_settings = uci.get('tailscale', 'settings') || {};
    // 清理uci返回的 .name 和 .type
    for (let key in uci_settings) {
        if (key.charAt(0) !== '.') {
            settings[key] = uci_settings[key];
        }
    }
    
    // 2. 从 state file 加载运行时配置来覆盖显示
    // 这是一个简化版本，只处理了部分字段
    let state_file_path = settings.state_file || "/etc/tailscale/tailscaled.state";
    if (fs.access(state_file_path)) {
        try {
            let state_data = JSON.parse(fs.readfile(state_file_path));
            let profile_key = Object.keys(state_data).find(k => k.startsWith('profile-'));
            if (profile_key && state_data[profile_key]) {
                let profile_detail_b64 = state_data[profile_key];
                let profile_detail_json = ubase64.decode(profile_detail_b64);
                let pdd = JSON.parse(profile_detail_json);

                settings.accept_routes = pdd.RouteAll;
                settings.advertise_exit_node = pdd.ExitNodeID === "" && pdd.AdvertiseRoutes && pdd.AdvertiseRoutes.length > 0;
                settings.advertise_routes = (pdd.AdvertiseRoutes || []).join(', ');
                settings.exit_node = pdd.ExitNodeID || "";
                settings.exit_node_allow_lan_access = pdd.ExitNodeAllowLANAccess;
                settings.hostname = pdd.Hostname || "";
                settings.snat_subnet_routes = !pdd.NoSNAT;
                settings.shields_up = pdd.ShieldsUp;
                settings.ssh = pdd.RunSSH;
                settings.auto_update = pdd.AutoUpdate && pdd.AutoUpdate.Check || false;
            }
        } catch(e) { /* ignore */ }
    }

    return settings;
};

// 保存配置
tailscale.set_settings = function(form_data) {
    // 1. 处理 Node Settings (通过 `tailscale set`)
    let args = ['set'];
    args.push('--accept-routes=' + (form_data.accept_routes === '1'));
    args.push('--advertise-exit-node=' + (form_data.advertise_exit_node === '1'));
    args.push('--exit-node-allow-lan-access=' + (form_data.exit_node_allow_lan_access === '1'));
    args.push('--snat-subnet-routes=' + (form_data.snat_subnet_routes === '1'));
    args.push('--ssh=' + (form_data.ssh === '1'));
    args.push('--shields-up=' + (form_data.shields_up === '1'));
    args.push('--auto-update=' + (form_data.auto_update === '1'));
    args.push('--advertise-routes=' + (form_data.advertise_routes || ""));
    args.push('--exit-node=' + (form_data.exit_node || ""));
    args.push('--hostname=' + (form_data.hostname || ""));

    let set_result = fs.exec('tailscale', args);
    if (set_result.code !== 0) {
        return { error: 'Failed to apply node settings: ' + set_result.stderr };
    }

    // 2. 处理 Daemon Environment Settings (通过 UCI 和 profile script)
    uci.load('tailscale');
    let old_mtu = uci.get('tailscale', 'settings', 'daemon_mtu') || "";
    let old_reduce_mem = uci.get('tailscale', 'settings', 'daemon_reduce_memory') || "0";
    
    let new_mtu = form_data.daemon_mtu || "";
    let new_reduce_mem = form_data.daemon_reduce_memory || "0";

    uci.set('tailscale', 'settings', 'daemon_mtu', new_mtu);
    uci.set('tailscale', 'settings', 'daemon_reduce_memory', new_reduce_mem);
    uci.save('tailscale');
    uci.commit('tailscale');

    // 检查守护进程设置是否改变
    if (new_mtu !== old_mtu || new_reduce_mem !== old_reduce_mem) {
        const env_script_path = "/etc/profile.d/tailscale-env.sh";
        const env_script_content = `#!/bin/sh
# This script is managed by luci-app-tailscale-community.
uci_get_state() { uci get tailscale.settings."$1" 2>/dev/null; }
if [ "$(uci_get_state daemon_reduce_memory)" = "1" ]; then export GOGC=10; fi
TS_MTU=$(uci_get_state daemon_mtu)
if [ -n "$TS_MTU" ]; then export TS_DEBUG_MTU="$TS_MTU"; fi
`;
        
        if (new_mtu !== "" || new_reduce_mem === "1") {
            fs.writefile(env_script_path, env_script_content);
            util.exec('chmod +x ' + env_script_path);
        } else {
            fs.remove(env_script_path);
        }
        
        // 异步重启服务
        util.exec('/etc/init.d/tailscale restart &');
    }

    return { success: true };
};