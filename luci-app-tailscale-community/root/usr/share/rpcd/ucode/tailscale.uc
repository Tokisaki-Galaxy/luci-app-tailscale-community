#!/usr/bin/env ucode

'use strict';

import { access, popen, readfile, writefile, unlink } from 'fs';
import { cursor } from 'uci';

const uci = cursor();

function exec(command, args) {
    const cmd_array = [command, ...(args || [])];
    let p = popen(cmd_array, 'r');
    if (!p) {
        return { code: -1, stdout: '', stderr: `Failed to execute: ${command}` };
    }
    let stdout_content = p.read('all') || '';
    let exit_code = p.close();
    let stderr_content = '';
    if (exit_code !== 0) {
        stderr_content = stdout_content;
    }
    return { code: exit_code, stdout: stdout_content, stderr: stderr_content };
}

const methods = {};

methods.is_installed = {
    call: function() {
        const is_found = access('/usr/sbin/tailscale') || access('/usr/bin/tailscale');
        // 关键修复：必须返回一个对象
        return { installed: is_found };
    }
};

methods.get_status = {
    call: function() {
        // 这个函数已经返回对象，是正确的
        let data = {
            running: false,
            ipv4: "Not running",
            ipv6: null,
            domain_name: "Unknown",
            peers: []
        };
        // ... (其余代码保持不变)
        let ip_output = exec('tailscale', ['ip']);
        if (ip_output.code === 0 && ip_output.stdout) {
            data.running = true;
            let lines = ip_output.stdout.trim().split('\n');
            data.ipv4 = lines[0] || "N/A";
            if (lines.length > 1) {
                data.ipv6 = lines[1];
            }
        }
        let status_json_output = exec('tailscale', ['status', '--json']);
        let peer_map = {};
        if (status_json_output.code === 0 && status_json_output.stdout) {
            try {
                let status_data = JSON.parse(status_json_output.stdout);
                if (status_data.Peer) {
                    for (let key in status_data.Peer) {
                        let peer = status_data.Peer[key];
                        if (peer.TailscaleIPs && peer.TailscaleIPs.length > 0) {
                            peer_map[peer.TailscaleIPs[0]] = peer;
                        }
                    }
                }
            } catch (e) { /* ignore */ }
        }
        let status_plain_output = exec('tailscale', ['status']);
        if (status_plain_output.code === 0 && status_plain_output.stdout) {
            status_plain_output.stdout.trim().split('\n').forEach(line => {
                let parts = line.trim().split(/\s+/);
                if (parts.length >= 5) {
                    let ip = parts[0];
                    if (peer_map[ip]) {
                        peer_map[ip].ConnectionInfo = parts.slice(4).join(' ');
                    }
                }
            });
        }
        for (let key in peer_map) {
            data.peers.push(peer_map[key]);
        }
        data.peers.sort((a, b) => (a.HostName || '').localeCompare(b.HostName || ''));
        uci.load('tailscale');
        let state_file_path = uci.get('tailscale', 'settings', 'state_file') || "/var/lib/tailscale/tailscaled.state";
        if (access(state_file_path)) {
            try {
                let state_content = readfile(state_file_path);
                if (state_content) {
                    let state_data = JSON.parse(state_content);
                    if (state_data && state_data.MagicDNSSuffix) {
                        data.domain_name = state_data.MagicDNSSuffix;
                    }
                }
            } catch (e) { /* ignore */ }
        }
        return data;
    }
};

methods.get_settings = {
    call: function() {
        // 这个函数已经返回对象，是正确的
        let settings = {};
        // ... (其余代码保持不变)
        uci.load('tailscale');
        let uci_settings = uci.get('tailscale', 'settings') || {};
        for (let key in uci_settings) {
            if (key.charAt(0) !== '.') {
                settings[key] = uci_settings[key];
            }
        }
        let status_output = exec('tailscale', ['status', '--json']);
        if (status_output.code === 0 && status_output.stdout) {
            try {
                let status_data = JSON.parse(status_output.stdout);
                if (status_data.Self) {
                    const self = status_data.Self;
                    const prefs = self.Prefs || {};
                    settings.accept_routes = prefs.RouteAll;
                    settings.advertise_exit_node = prefs.AdvertiseExitNode;
                    settings.advertise_routes = (prefs.AdvertiseRoutes || []).join(', ');
                    settings.exit_node = prefs.ExitNodeID || "";
                    settings.exit_node_allow_lan_access = prefs.ExitNodeAllowLANAccess;
                    settings.hostname = self.HostName || "";
                    settings.shields_up = prefs.ShieldsUp;
                    settings.ssh = (self.Capabilities || []).includes("ssh");
                }
            } catch (e) { /* ignore */ }
        }
        return settings;
    }
};

methods.set_settings = {
    args: { form_data: 'form_data' },
    call: function(params) {
        // 这个函数已经返回对象，是正确的
        const form_data = params.form_data;
        // ... (其余代码保持不变)
        let args = ['set'];
        args.push('--accept-routes=' + (form_data.accept_routes === '1'));
        args.push('--advertise-exit-node=' + (form_data.advertise_exit_node === '1'));
        args.push('--exit-node-allow-lan-access=' + (form_data.exit_node_allow_lan_access === '1'));
        args.push('--ssh=' + (form_data.ssh === '1'));
        args.push('--shields-up=' + (form_data.shields_up === '1'));
        args.push('--advertise-routes=' + (form_data.advertise_routes || ""));
        args.push('--exit-node=' + (form_data.exit_node || ""));
        args.push('--hostname=' + (form_data.hostname || ""));
        let set_result = exec('tailscale', args);
        if (set_result.code !== 0) {
            return { error: 'Failed to apply node settings: ' + set_result.stderr };
        }
        uci.load('tailscale');
        let old_mtu = uci.get('tailscale', 'settings', 'daemon_mtu') || "";
        let old_reduce_mem = uci.get('tailscale', 'settings', 'daemon_reduce_memory') || "0";
        let new_mtu = form_data.daemon_mtu || "";
        let new_reduce_mem = form_data.daemon_reduce_memory || "0";
        uci.set('tailscale', 'settings', 'daemon_mtu', new_mtu);
        uci.set('tailscale', 'settings', 'daemon_reduce_memory', new_reduce_mem);
        uci.save('tailscale');
        uci.commit('tailscale');
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
                writefile(env_script_path, env_script_content, 0o755);
            } else {
                unlink(env_script_path);
            }
            exec('/bin/sh', ['-c', '/etc/init.d/tailscale restart &']);
        }
        return { success: true };
    }
};

return { 'tailscale': methods };