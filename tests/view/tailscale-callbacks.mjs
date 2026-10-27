'use strict';
/*
 * Callback tests for the LuCI view.
 *
 * The view file cannot be imported by node: its 'require xxx' lines are LuCI
 * directives and the body expects the browser globals LuCI injects. LuCI
 * itself evaluates the module body inside a function whose parameters are the
 * required modules, so the test does the same with stubs and captures the
 * button callbacks as the form is built.
 *
 * Run: node tests/view/tailscale-callbacks.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const viewPath = join(here, '../../luci-app-tailscale-community/htdocs/luci-static/resources/view/tailscale.js');
const source = readFileSync(viewPath, 'utf8').replace(/^\s*'require [^']+';\s*$/gm, '');

let passes = 0;
let failures = 0;

// LuCI extends the String prototype; the view relies on it.
if (typeof String.prototype.format !== 'function') {
	String.prototype.format = function() {
		const args = Array.prototype.slice.call(arguments);
		return this.replace(/%[sd]/g, function() { return String(args.shift()); });
	};
}

function check(name, condition, detail) {
	if (condition === true) {
		passes++;
		return;
	}
	failures++;
	console.log('  FAIL: ' + name + (detail ? ' -> ' + detail : ''));
}

function textOf(node) {
	if (node == null) return '';
	if (typeof node === 'string') return node;
	if (Array.isArray(node)) return node.map(textOf).join(' ');
	if (node.children) return node.children.map(textOf).join(' ');
	return '';
}

function E(tag, attrs, children) {
	if (Array.isArray(tag)) {
		children = tag;
		tag = 'div';
		attrs = {};
	}
	if (typeof attrs !== 'object' || attrs === null || Array.isArray(attrs)) {
		children = attrs;
		attrs = {};
	}
	if (typeof children === 'string' || typeof children === 'number') children = [ String(children) ];
	return { tag: tag, attrs: attrs || {}, children: Array.isArray(children) ? children : [] };
}

const settle = function() { return new Promise(function(r) { setTimeout(r, 60); }); };

function makeHarness(responses, opts) {
	opts = opts || {};
	const notifications = [];
	const calls = [];
	const buttons = {};
	const options = {};
	const elements = {};
	const modals = [];
	let pollFns = [];
	// what the uci stub returns; opts.submitted lands here when the form is saved
	const uciValues = Object.assign({}, opts.saved);

	function makeOption(name) {
		const self = {
			name: name || null,
			title: null,
			taboption: function(t, type, optName) {
				return makeOption(optName);
			},
			value: function() { return self; },
			depends: function() { return self; },
			tab: function() {},
			section: function() { return self; },
			render: function() { return E('div', {}, []); }
		};
		Object.defineProperty(self, 'onclick', {
			get: function() { return self._onclick; },
			set: function(fn) {
				self._onclick = fn;
				if (self.name) buttons[self.name] = fn;
			}
		});
		if (name) options[name] = self;
		return self;
	}

	function makeSection() {
		const s = makeOption();
		s.section = function() { return s; };
		// like Map.save(): parsing the form puts the submitted values into the uci model, then the callback runs
		s.save = function(cb) {
			Object.assign(uciValues, opts.submitted);
			return Promise.resolve(typeof cb === 'function' ? cb() : undefined);
		};
		s.parse = function() { return Promise.resolve(); };
		s.render = function() { return E('div', {}, []); };
		return s;
	}

	const formStub = new Proxy({ Map: function() { return makeSection(); } }, {
		get: function(target, prop) {
			if (prop in target) return target[prop];
			return function() { return makeOption(); };
		}
	});

	const rpc = {
		declare: function(opt) {
			return function(args) {
				// like rpc.declare(): positional arguments are mapped to the declared params
				const argv = Array.prototype.slice.call(arguments);
				const wire = {};
				(opt.params || []).forEach(function(name, i) { wire[name] = argv[i]; });
				calls.push({ method: opt.method, args: args, wire: wire });
				const v = responses[opt.method];
				if (v instanceof Error) return Promise.reject(v);
				return Promise.resolve(typeof v === 'function' ? v(args) : v);
			};
		}
	};

	const ui = {
		addNotification: function(t, node, c) {
			notifications.push({ text: textOf(node), cls: c || 'info' });
			return {};
		},
		addTimeLimitedNotification: function(t, nodes, ms, c) {
			notifications.push({ text: (nodes || []).map(textOf).join(' '), cls: c || 'info' });
		},
		showModal: function(title, content) {
			modals.push(content);
		},
		hideModal: function() {},
		changes: { apply: function() { return Promise.resolve(); } }
	};

	const L = {
		resolveDefault: function(p, d) { return Promise.resolve(p).catch(function() { return d; }); },
		Poll: {
			add: function(fn) { if (pollFns.indexOf(fn) === -1) pollFns.push(fn); },
			remove: function(fn) { pollFns = pollFns.filter(function(f) { return f !== fn; }); }
		}
	};

	const uci = {
		load: function() { return Promise.resolve(); },
		get: function(name, s, o) {
			// pretend the settings section exists so load() skips first-run init
			if (o === undefined && s === 'settings') return 'settings';
			return o in uciValues ? uciValues[o] : null;
		},
		set: function() {},
		add: function() {},
		unset: function() {},
		changes: function() {
			return Promise.resolve(opts.pending ? { tailscale: [ 'settings.advertise_routes' ] } : {});
		},
		save: function() { return Promise.resolve(); }
	};

	const factory = new Function(
		'view', 'form', 'rpc', 'ui', 'uci', 'E', '_', 'L', 'document', 'window', 'localStorage',
		source
	);

	const obj = factory(
		{ extend: function(o) { return o; } },
		formStub, rpc, ui, uci, E,
		function(s) { return s; },
		L,
		{ getElementById: function(id) { return elements[id] || null; }, createElement: function() { return {}; } },
		{
			setTimeout: function(fn, ms) { return setTimeout(fn, opts.realTimers ? ms : Math.min(ms, 5)); },
			open: function() { return null; }
		},
		{ getItem: function() { return null; }, setItem: function() {} }
	);

	return {
		obj: obj,
		calls: calls,
		notifications: notifications,
		// load() gathers the staged-changes snapshot, render() builds the form
		start: async function() {
			await L.resolveDefault(obj.load(), []);
			await settle();
			await obj.render([ {}, { accept_routes: false }, { routes: [] } ]);
		},
		button: function(name) {
			return buttons[name];
		},
		option: function(name) {
			return options[name];
		},
		setElement: function(id, node) {
			elements[id] = node;
		},
		modals: function() {
			return modals;
		},
		pollers: function() {
			return pollFns.slice();
		}
	};
}

async function press(node) {
	if (!node || typeof node !== 'object') return false;
	if (node.tag === 'button' && node.attrs && node.attrs['class'] === 'cbi-button cbi-button-negative') {
		await node.attrs.click();
		return true;
	}
	for (const child of (node.children || [])) {
		if (await press(child)) return true;
	}
	return false;
}

async function run() {
	console.log('test: the view loads and the firewall callback is attached');
	const h0 = makeHarness({});
	await h0.start();
	check('the firewall callback exists', typeof h0.button('_setup_firewall') === 'function');
	check('the logout callback exists', typeof h0.button('_logout') === 'function');
	check('the logs callback exists', typeof h0.button('_refresh_logs') === 'function');

	console.log('test: { error } from setup_firewall is shown as an error');
	const h1 = makeHarness({ setup_firewall: { error: 'Exception in setup_firewall: boom' } });
	await h1.start();
	await h1.button('_setup_firewall')();
	check('exactly one error notification',
		h1.notifications.filter(function(n) { return n.cls === 'error'; }).length === 1,
		JSON.stringify(h1.notifications));
	check('the backend message is surfaced',
		h1.notifications.some(function(n) { return n.text.indexOf('boom') !== -1; }),
		JSON.stringify(h1.notifications));
	check('no success notification',
		h1.notifications.every(function(n) { return n.cls !== 'info'; }),
		JSON.stringify(h1.notifications));

	console.log('test: success polls the background job until done');
	const h2 = makeHarness({
		setup_firewall: { success: true, changed_network: true, changed_firewall: true, run_id: 7 },
		get_firewall_status: { success: true, state: 'done', run_id: 7 }
	});
	await h2.start();
	await h2.button('_setup_firewall')();
	await settle();
	check('get_firewall_status was called',
		h2.calls.some(function(c) { return c.method === 'get_firewall_status'; }),
		JSON.stringify(h2.calls.map(function(c) { return c.method; })));
	check('completion is announced',
		h2.notifications.some(function(n) { return n.text.indexOf('applied') !== -1; }),
		JSON.stringify(h2.notifications));
	check('nothing failed',
		h2.notifications.every(function(n) { return n.cls !== 'error'; }),
		JSON.stringify(h2.notifications));

	console.log('test: a failed background job is reported');
	const h3 = makeHarness({
		setup_firewall: { success: true, changed_network: true, changed_firewall: false, run_id: 8 },
		get_firewall_status: { success: true, state: 'failed', message: 'Network reload failed', run_id: 8 }
	});
	await h3.start();
	await h3.button('_setup_firewall')();
	await settle();
	check('an error notification is shown',
		h3.notifications.some(function(n) { return n.cls === 'error'; }),
		JSON.stringify(h3.notifications));
	check('the job message is surfaced',
		h3.notifications.some(function(n) { return n.text.indexOf('Network reload failed') !== -1; }),
		JSON.stringify(h3.notifications));

	console.log('test: nothing changed means no polling');
	const h4 = makeHarness({
		setup_firewall: { success: true, changed_network: false, changed_firewall: false, run_id: 0 }
	});
	await h4.start();
	await h4.button('_setup_firewall')();
	await settle();
	check('no polling happens',
		!h4.calls.some(function(c) { return c.method === 'get_firewall_status'; }),
		JSON.stringify(h4.calls.map(function(c) { return c.method; })));
	check('the user is told it was already applied',
		h4.notifications.some(function(n) { return n.text.indexOf('already applied') !== -1; }),
		JSON.stringify(h4.notifications));

	console.log('test: transport failures reach the user');
	const h5 = makeHarness({ setup_firewall: new Error('XHR request aborted by browser') });
	await h5.start();
	await h5.button('_setup_firewall')();
	check('the abort text is kept',
		h5.notifications.some(function(n) { return n.text.indexOf('XHR request aborted') !== -1; }),
		JSON.stringify(h5.notifications));

	console.log('test: a result from a previous run is not accepted');
	const h6 = makeHarness({
		setup_firewall: { success: true, changed_network: true, changed_firewall: false, run_id: 200 },
		// the only answer available belongs to an earlier run and says done
		get_firewall_status: { success: true, state: 'done', run_id: 100 }
	}, { realTimers: true });
	await h6.start();
	await h6.button('_setup_firewall')();
	await settle();
	const stalePass = h6.notifications.slice();
	check('the earlier run was polled', h6.calls.some(function(c) { return c.method === 'get_firewall_status'; }),
		JSON.stringify(h6.calls.map(function(c) { return c.method; })));
	check('its outcome is not announced as this run\'s',
		!stalePass.some(function(n) { return n.text.indexOf('applied') !== -1; }),
		JSON.stringify(stalePass));

	console.log('test: an empty reply does not leak its format placeholder');
	const h7 = makeHarness({ setup_firewall: null });
	await h7.start();
	await h7.button('_setup_firewall')();
	check('no %s reaches the user',
		h7.notifications.every(function(n) { return n.text.indexOf('%s') === -1; }),
		JSON.stringify(h7.notifications));
	check('the prefix is not duplicated',
		h7.notifications.every(function(n) { return (n.text.match(/Failed to configure firewall/g) || []).length <= 1; }),
		JSON.stringify(h7.notifications));

	console.log('test: logout reports the backend error instead of success');
	const h8 = makeHarness({ do_logout: { error: 'Tailscale is not running. Cannot perform logout.' } });
	await h8.start();
	await h8.button('_logout')();
	for (const modal of h8.modals())
		await press(modal);
	await settle();
	check('logout does not claim success',
		!h8.notifications.some(function(n) { return n.text.indexOf('Successfully logged out') !== -1; }),
		JSON.stringify(h8.notifications));
	check('logout surfaces the reason',
		h8.notifications.some(function(n) { return n.text.indexOf('Cannot perform logout') !== -1; }),
		JSON.stringify(h8.notifications));

	console.log('test: log loading reports the backend error');
	const logNode = { replaced: null, replaceChildren: function() { this.replaced = Array.prototype.slice.call(arguments); } };
	const h9 = makeHarness({ get_logs: { success: false, logs: [], error: 'logread unavailable' } });
	await h9.start();
	h9.setElement('tailscale_logs_display', logNode);
	await h9.button('_refresh_logs')();
	await settle();
	const logText = textOf(logNode.replaced);
	check('the log error is surfaced', logText.indexOf('logread unavailable') !== -1, logText);

	console.log('test: unsaved changes are pointed out without blocking the work');
	// The warning is advisory: blocking on a stale answer would make the
	// button unusable after the first save on the same page.
	const h10 = makeHarness({
		setup_firewall: { success: true, changed_network: true, changed_firewall: true, run_id: 5 },
		get_firewall_status: { success: true, state: 'done', run_id: 5 }
	}, { pending: true });
	await h10.start();
	await h10.button('_setup_firewall')();
	await settle();
	check('the user is told to save first',
		h10.notifications.some(function(n) { return n.text.indexOf('unapplied changes') !== -1; }),
		JSON.stringify(h10.notifications));
	check('the setup still runs',
		h10.calls.some(function(c) { return c.method === 'setup_firewall'; }),
		JSON.stringify(h10.calls.map(function(c) { return c.method; })));

	console.log('test: no warning when nothing is staged');
	const h11 = makeHarness({
		setup_firewall: { success: true, changed_network: false, changed_firewall: false, run_id: 0 }
	});
	await h11.start();
	await h11.button('_setup_firewall')();
	await settle();
	check('no unsaved-changes warning appears',
		!h11.notifications.some(function(n) { return n.text.indexOf('unapplied changes') !== -1; }),
		JSON.stringify(h11.notifications));

	console.log('test: a busy worker is reported instead of waiting to time out');
	const h12 = makeHarness({
		setup_firewall: { success: true, changed_network: true, changed_firewall: false, run_id: 9 },
		get_firewall_status: { success: true, state: 'busy', message: 'Another firewall reload is already running', run_id: 0 }
	});
	await h12.start();
	await h12.button('_setup_firewall')();
	await settle();
	check('the busy message reaches the user',
		h12.notifications.some(function(n) { return n.text.indexOf('already running') !== -1; }),
		JSON.stringify(h12.notifications));
	check('it does not wait for the timeout',
		!h12.notifications.some(function(n) { return n.text.indexOf('Timed out') !== -1; }),
		JSON.stringify(h12.notifications));

	console.log('test: the firewall help text mentions WAN and the Exit Node steps');
	const h13 = makeHarness({});
	await h13.start();

	// Issue #82: the description named LAN and Tailscale only, so a user with
	// an Exit Node concluded the button did not cover WAN. Each claim is
	// asserted separately, because one sentence containing "WAN" is not
	// enough: dropping either of the first two must fail here.
	const desc = String((h13.option('_setup_firewall') || {}).description || '');

	check('the description names the LAN and Tailscale directions',
		desc.indexOf('forwarding between LAN and Tailscale') !== -1, desc);
	check('the description names Tailscale to WAN as a separate direction',
		desc.indexOf('plus Tailscale to WAN') !== -1, desc);
	check('the description explains what the WAN forwarding is for',
		desc.indexOf('The Tailscale to WAN forwarding is what lets clients') !== -1,
		desc);
	check('the description does not claim a full mesh',
		desc.indexOf('between LAN, Tailscale and WAN') === -1, desc);

	const exitHelp = h13.option('_exit_node_help');
	check('the exit node help block exists', !!exitHelp);

	const texts = [];
	(function collect(node) {
		if (!node) return;
		if (typeof node === 'string') texts.push(node);
		if (Array.isArray(node)) { node.forEach(collect); return; }
		if (node.attrs && typeof node.attrs === 'string') texts.push(node.attrs);
		(node.children || []).forEach(collect);
	})(exitHelp && exitHelp.render ? exitHelp.render.call(exitHelp) : null);

	const joined = texts.join('\n');
	check('the exit node help has four numbered steps',
		[ '1. ', '2. ', '3. ', '4. ' ].every(function(n) {
			return texts.some(function(t) { return t.indexOf(n) === 0; });
		}),
		joined.slice(0, 400));
	check('the exit node help names the admin console approval',
		joined.indexOf('admin console') !== -1, joined.slice(0, 400));

	console.log('test: turning the service off in the form sends the stop request');
	// The submitted value only reaches the uci model while map.save() parses the
	// form, and the declared rpc maps positional arguments to its params. Reading
	// the value before the save, or passing { enabled: value }, never arms the request.
	const h14 = makeHarness({ set_service_enabled: { success: true, armed: true } },
		{ saved: { service_enabled: '1' }, submitted: { service_enabled: '0' } });
	await h14.start();
	await h14.obj.handleSaveApply({}, '0');
	const off = h14.calls.filter(function(c) { return c.method === 'set_service_enabled'; });
	check('set_service_enabled is called once', off.length === 1, JSON.stringify(off));
	check('it is sent the submitted value 0 as a plain string',
		off.length === 1 && off[0].wire.enabled === '0', JSON.stringify(off));

	console.log('test: turning the service on in the form clears the stop request');
	const h15 = makeHarness({ set_service_enabled: { success: true, armed: false } },
		{ saved: { service_enabled: '0' }, submitted: { service_enabled: '1' } });
	await h15.start();
	await h15.obj.handleSaveApply({}, '0');
	const on = h15.calls.filter(function(c) { return c.method === 'set_service_enabled'; });
	check('it is sent the submitted value 1 as a plain string',
		on.length === 1 && on[0].wire.enabled === '1', JSON.stringify(on));

	console.log('');
	console.log('passed: ' + passes + '  failed: ' + failures);
	process.exit(failures === 0 ? 0 : 1);
}

run().catch(function(e) {
	console.error(e);
	process.exit(1);
});
