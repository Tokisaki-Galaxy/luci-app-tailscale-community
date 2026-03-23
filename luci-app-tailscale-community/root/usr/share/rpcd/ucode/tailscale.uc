#!/usr/bin/env ucode

'use strict';

import { access, popen, readfile, writefile, unlink } from 'fs';
import { cursor } from 'uci';

const uci = cursor();
const diagnostics_file = '/var/run/tailscale-settings-diagnostics.json';

function exec(command) {
	let stdout_content = '';
	let p = popen(command, 'r');
	sleep(100);
	if (p == null) {
		return { code: -1, stdout: '', stderr: `Failed to execute: ${command}` };
	}
	for (let line = p.read('line'); length(line); line = p.read('line')) {
		stdout_content = stdout_content+line;
	}
	stdout_content = rtrim(stdout_content);
	stdout_content = split(stdout_content, '\n');

	let exit_code = p.close();
	let stderr_content = '';
	if (exit_code != 0) {
		stderr_content = stdout_content;
	}
	return { code: exit_code, stdout: stdout_content, stderr: stderr_content };
}

function shell_quote(s) {
	if (s == null || s == '') return "''";
	return "'" + replace(s, "'", "'\\''") + "'";
}

function read_json_command(command) {
	let result = exec(command);
	if (result.code != 0 || length(result.stdout) == 0) {
		return null;
	}

	try {
		return json(join('', result.stdout));
	} catch (e) {
		return null;
	}
}

function normalize_runtime(status_data, prefs_data) {
	let advertise_routes = prefs_data?.AdvertiseRoutes || [];
	let advertise_exit_node = status_data?.AdvertiseExitNode || false;

	for (let route in advertise_routes) {
		if (advertise_routes[route] == '0.0.0.0/0' || advertise_routes[route] == '::/0') {
			advertise_exit_node = true;
		}
	}

	return {
		accept_routes: prefs_data?.RouteAll || false,
		advertise_exit_node: advertise_exit_node,
		advertise_routes: advertise_routes,
		exit_node: prefs_data?.ExitNodeIP || prefs_data?.ExitNodeID || '',
		exit_node_allow_lan_access: prefs_data?.ExitNodeAllowLANAccess || false,
		shields_up: prefs_data?.ShieldsUp || false,
		ssh: prefs_data?.RunSSH || false,
		runwebclient: prefs_data?.RunWebClient || false,
		nosnat: prefs_data?.NoSNAT || false,
		disable_magic_dns: !(prefs_data?.CorpDNS || false),
		hostname: prefs_data?.Hostname || '',
		enable_relay: prefs_data?.RelayServerPort ? true : false,
		relay_server_port: prefs_data?.RelayServerPort || '',
		login_server: prefs_data?.ControlURL || '',
		logged_in: status_data?.BackendState == 'Running',
		self_active: status_data?.Self?.Active || false,
		self_in_engine: status_data?.Self?.InEngine || false,
		ipv4: status_data?.Self?.TailscaleIPs?.[0] || '',
		ipv6: status_data?.Self?.TailscaleIPs?.[1] || ''
	};
}

const methods = {};

methods.get_status = {
	call: function() {
		let data = {
			status: '',
			version: '',
			TUNMode: '',
			health: '',
			ipv4: "Not running",
			ipv6: null,
			domain_name: '',
			peers: []
		};
		if (access('/usr/sbin/tailscale')==true || access('/usr/bin/tailscale')==true){ }else{
			data.status = 'not_installed';
			return data;
		}

		let status_json_output = exec('tailscale status --json');
		let peer_map = {};
		if (status_json_output.code == 0 && length(status_json_output.stdout) > 0) {
			try {
				let status_data = json(join('',status_json_output.stdout));
				data.version = status_data?.Version || 'Unknown';
				data.health = status_data?.Health || '';
				data.TUNMode = status_data?.TUN || 'true';
				if (status_data?.BackendState == 'Running') { data.status =  'running'; }
				if (status_data?.BackendState == 'NeedsLogin') { data.status =  'logout'; }

				data.ipv4 = status_data?.Self?.TailscaleIPs?.[0] || 'No IP assigned';
				data.ipv6 = status_data?.Self?.TailscaleIPs?.[1] || null;
				data.domain_name = status_data?.CurrentTailnet?.Name || '';

				// peers list
				for (let p in status_data?.Peer) {
					p = status_data.Peer[p];
					peer_map[p.ID] = {
						ip: join('<br>', p?.TailscaleIPs) || '',
						hostname: split(p?.DNSName || '','.')[0] || '',
						ostype: p?.OS,
						online: p?.Online,
						linkadress: (!p?.CurAddr) ? p?.Relay : p?.CurAddr,
						lastseen: p?.LastSeen,
						exit_node: !!p?.ExitNode,
						exit_node_option: !!p?.ExitNodeOption,
						tx: p?.TxBytes || '',
						rx: p?.RxBytes || ''
					};
				}
			} catch (e) { /* ignore */ }
		}

		data.peers = peer_map;
		return data;
	}
};

methods.get_runtime = {
	call: function() {
		uci.load('tailscale');
		let runtime = normalize_runtime(
			read_json_command('tailscale status --json') || {},
			read_json_command('tailscale debug prefs --json') || {}
		);
		runtime.fw_mode = split(uci.get('tailscale', 'settings', 'fw_mode'), ' ')[0] || 'nftables';
		return runtime;
	}
};

methods.get_settings = {
	call: function() {
		return methods.get_runtime.call();
	}
};

methods.get_diagnostics = {
	call: function() {
		let defaults = {
			apply_mode: 'unknown',
			exit_code: -1,
			logged_in: false,
			self_active: false,
			self_in_engine: false,
			ts_ip4: '',
			table52_has_routes: false,
			table_route_count: 0,
			peer_candidate: '',
			peer_route_ok: false,
			peer_route_status: 'unavailable',
			peer_route_summary: '',
			table52_summary: '',
			health: 'warn',
			reason: 'unavailable'
		};

		if (!access(diagnostics_file)) {
			return defaults;
		}

		try {
			let diagnostics = json(readfile(diagnostics_file));
			for (let key in defaults) {
				if (diagnostics?.[key] == null) {
					diagnostics[key] = defaults[key];
				}
			}
			return diagnostics;
		} catch (e) {
			return defaults;
		}
	}
};


methods.do_login = {
	args: { form_data: {} },
	call: function(request) {
		const form_data = request.args.form_data;
		let loginargs = [];
		if (form_data == null || length(form_data) == 0) {
			return { error: 'Missing or invalid form_data parameter. Please provide login data.' };
		}

		let status=methods.get_status.call();
		if (status.status != 'logout') {
			return { error: 'Tailscale is already logged in and running.' };
		}

		// --- 1. Prepare and Run Login Command (Once) ---
		const loginserver = trim(form_data.loginserver) || '';
		const loginserver_authkey = trim(form_data.loginserver_authkey) || '';

		if (loginserver!='') {
			push(loginargs,'--login-server '+shell_quote(loginserver));
			if (loginserver_authkey!='') {
				push(loginargs,'--auth-key '+shell_quote(loginserver_authkey));
			}
		}

		// Run the command in the background using /bin/sh -c to handle the '&' correctly
		let login_cmd = 'tailscale login '+join(' ', loginargs);
		popen('/bin/sh -c "' + login_cmd + ' &"', 'r');

		// --- 2. Loop to Check Status for URL ---
		let max_attempts = 15;
		let interval = 2000;

		for (let i = 0; i < max_attempts; i++) {
			let tresult = exec('tailscale status');
			for (let line in tresult.stdout) {
				let trline = trim(line);
				if (index(trline, 'http') != -1) {
					let parts = split(trline, ' ');
					for (let part in parts) {
						if (index(part, 'http') != -1) {
							return { url: part };
						}
					}
				}
			}
			sleep(interval);
		}
		return { error: 'Could not retrieve login URL from tailscale command after 30 seconds.' };
	}
};

methods.do_logout = {
	call: function() {
		let status=methods.get_status.call();
		if (status.status != 'running') {
			return { error: 'Tailscale is not running. Cannot perform logout.' };
		}

		let logout_result = exec('tailscale logout');
		if (logout_result.code != 0) {
			return { error: 'Failed to logout: ' + logout_result.stderr };
		}
		return { success: true };
	}
};

methods.get_subroutes = {
	call: function() {
		try {
			let cmd = 'ip -j route';
			let result = exec(cmd);
			let subnets = [];

			if (result.code == 0 && length(result.stdout) > 0) {
				let routes_json = json(join('',result.stdout));

				for (let route in routes_json) {
					// We need to filter out local subnets
					// 1. 'dst' (target address) is not' default' (default gateway)
					// 2. 'scope' is' link' (indicating directly connected network)
					// 3. It is an IPv4 address (simple judgment: including'.')
					if (route?.dst && route.dst != 'default' && route?.scope == 'link' && index(route.dst,'.') != -1) {
						push(subnets,route.dst);
					}
				}
			}
			return { routes: subnets };
		}
		catch(e) {
			return { routes: [] };
		}
	}
};

methods.setup_firewall = {
	call: function() {
		try {
			uci.load('network');
			uci.load('firewall');

			let changed_network = false;
			let changed_firewall = false;

			// 1. config Network Interface
			let net_ts = uci.get('network', 'tailscale');
			if (net_ts == null) {
				uci.set('network', 'tailscale', 'interface');
				uci.set('network', 'tailscale', 'proto', 'none');
				uci.set('network', 'tailscale', 'device', 'tailscale0');
				changed_network = true;
			} else {
				let current_dev = uci.get('network', 'tailscale', 'device');
				if (current_dev != 'tailscale0') {
					uci.set('network', 'tailscale', 'device', 'tailscale0');
					changed_network = true;
				}
			}

			// 2. config Firewall Zone
			let fw_all = uci.get_all('firewall');
			let ts_zone_section = null;
			let fwd_lan_to_ts = false;
			let fwd_ts_to_lan = false;

			for (let sec_key in fw_all) {
				let s = fw_all[sec_key];
				if (s['.type'] == 'zone' && s['name'] == 'tailscale') {
					ts_zone_section = sec_key;
				}
				if (s['.type'] == 'forwarding') {
					if (s.src == 'lan' && s.dest == 'tailscale') fwd_lan_to_ts = true;
					if (s.src == 'tailscale' && s.dest == 'lan') fwd_ts_to_lan = true;
				}
			}

			if (ts_zone_section == null) {
				let zid = uci.add('firewall', 'zone');
				uci.set('firewall', zid, 'name', 'tailscale');
				uci.set('firewall', zid, 'input', 'ACCEPT');
				uci.set('firewall', zid, 'output', 'ACCEPT');
				uci.set('firewall', zid, 'forward', 'ACCEPT');
				uci.set('firewall', zid, 'masq', '1');
				uci.set('firewall', zid, 'mtu_fix', '1');
				uci.set('firewall', zid, 'network', ['tailscale']);
				changed_firewall = true;
			} else {
				let nets = uci.get('firewall', ts_zone_section, 'network');
				let net_list = [];
				let has_ts_net = false;

				if (type(nets) == 'array') {
					net_list = nets;
				} else if (type(nets) == 'string') {
					net_list = [nets];
				}

				// check if 'tailscale' is already in the list
				for (let n in net_list) {
					if (net_list[n] == 'tailscale') {
						has_ts_net = true;
						break;
					}
				}

				if (!has_ts_net) {
					push(net_list, 'tailscale');
					uci.set('firewall', ts_zone_section, 'network', net_list);
					changed_firewall = true;
				}
			}

			// 3. config Forwarding
			if (!fwd_lan_to_ts) {
				let fid = uci.add('firewall', 'forwarding');
				uci.set('firewall', fid, 'src', 'lan');
				uci.set('firewall', fid, 'dest', 'tailscale');
				changed_firewall = true;
			}

			if (!fwd_ts_to_lan) {
				let fid = uci.add('firewall', 'forwarding');
				uci.set('firewall', fid, 'src', 'tailscale');
				uci.set('firewall', fid, 'dest', 'lan');
				changed_firewall = true;
			}

			// 4. save
			if (changed_network) {
				uci.save('network');
				uci.commit('network');
				exec('/etc/init.d/network reload');
			}

			if (changed_firewall) {
				uci.save('firewall');
				uci.commit('firewall');
				exec('/etc/init.d/firewall reload');
			}

			return {
				success: true,
				changed_network: changed_network,
				changed_firewall: changed_firewall,
				message: (changed_network || changed_firewall) ? 'Tailscale firewall/interface configuration applied.' : 'Tailscale firewall/interface already configured.'
			};

		} catch (e) {
			return { error: 'Exception in setup_firewall: ' + e + '\nStack: ' + (e.stacktrace || '') };
		}
	}
};

return { 'tailscale': methods };
