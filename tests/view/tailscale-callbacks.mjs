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
	if (condition) {
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
		// E([ ...children ]) form used by the modal bodies
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

function makeHarness(responses, opts) {
	const notifications = [];
	const calls = [];
	const buttons = {};
	const elements = {};
	const modals = [];
	const byName = buttons;

	function makeOption(name) {
		const self = {
			name: name,
			taboption: function(t, type, optName) {
				self.name = optName;
				return self;
			},
			value: function() { return self; },
			withDescription: function() { return self; },
			depends: function() { return self; },
			tab: function() {},
			section: function() { return self; },
			render: function() { return E('div', {}, []); }
		};
		Object.defineProperty(self, 'onclick', {
			get: function() { return self._onclick; },
			set: function(fn) {
				self._onclick = fn;
				byName[self.name] = fn;
			}
		});
		return self;
	}


	const mapObj = {
		section: function() { return makeOption(); },
		save: function() { return Promise.resolve(); },
		parse: function() { return Promise.resolve(); },
		render: function() { return E('div', {}, []); }
	};
	const formStub = new Proxy({ Map: function() { return mapObj; } }, {
		get: function(target, prop) {
			if (prop in target) return target[prop];
			return function() { return makeOption(); };
		}
	});

	const rpc = {
		declare: function(opt) {
			return function(args) {
				calls.push({ method: opt.method, args: args });
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
			// the logout flow opens a confirmation dialog; invoke the confirm
			// button's handler so the destructive branch is exercised
			modals.push(content);
		},
		hideModal: function() {},
		changes: { apply: function() { return Promise.resolve(); } }
	};

	const L = {
		resolveDefault: function(p, d) { return Promise.resolve(p).catch(function() { return d; }); },
		Poll: {
			add: function() {},
			remove: function() {}
		}
	};

	const uci = {
		load: function() { return Promise.resolve(); },
		get: function() { return null; },
		set: function() {},
		add: function() {},
		unset: function() {},
		changes: function() { return (opts && opts.pending) || []; },
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
		{ setTimeout: function(fn, ms) { return setTimeout(fn, Math.min(ms, 5)); } },
		{ getItem: function() { return null; }, setItem: function() {} }
	);

	return {
		obj: obj,
		calls: calls,
		notifications: notifications,
		buttons: buttons,
		setElement: function(id, node) {
			elements[id] = node;
		},
		modals: function() {
			return modals;
		},
		// callbacks are looked up by their form option name, not by order:
		// the view assigns several onclick handlers during render
		firewall: function() {
			return buttons['_setup_firewall'];
		},
		logout: function() {
			return buttons['_logout'];
		},
		refreshLogs: function() {
			return buttons['_refresh_logs'];
		}
	};
}

const settle = function() { return new Promise(function(r) { setTimeout(r, 50); }); };

async function run() {
	console.log('test: the view renders and the firewall callback is attached');
	const h0 = makeHarness({});
	await h0.obj.render([{}, {}, { routes: [] }]);
	check('render returned something', h0.obj != null);
	check('the firewall callback was captured', typeof h0.firewall() === 'function');

	console.log('test: { error } from setup_firewall is shown as an error');
	const h1 = makeHarness({ setup_firewall: { error: 'Exception in setup_firewall: boom' } });
	await h1.obj.render([{}, {}, { routes: [] }]);
	await h1.firewall()();
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
		setup_firewall: { success: true, changed_network: true, changed_firewall: true, job: 'running' },
		get_firewall_status: { success: true, state: 'done' }
	});
	await h2.obj.render([{}, {}, { routes: [] }]);
	await h2.firewall()();
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
		setup_firewall: { success: true, changed_network: true, changed_firewall: false, job: 'running' },
		get_firewall_status: { success: true, state: 'failed', message: 'Network reload failed' }
	});
	await h3.obj.render([{}, {}, { routes: [] }]);
	await h3.firewall()();
	await settle();
	check('an error notification is shown',
		h3.notifications.some(function(n) { return n.cls === 'error'; }),
		JSON.stringify(h3.notifications));
	check('the job message is surfaced',
		h3.notifications.some(function(n) { return n.text.indexOf('Network reload failed') !== -1; }),
		JSON.stringify(h3.notifications));

	console.log('test: nothing changed means no polling');
	const h4 = makeHarness({
		setup_firewall: { success: true, changed_network: false, changed_firewall: false, job: 'idle' }
	});
	await h4.obj.render([{}, {}, { routes: [] }]);
	await h4.firewall()();
	await settle();
	check('no polling happens',
		!h4.calls.some(function(c) { return c.method === 'get_firewall_status'; }),
		JSON.stringify(h4.calls.map(function(c) { return c.method; })));
	check('the user is told it was already applied',
		h4.notifications.some(function(n) { return n.text.indexOf('already applied') !== -1; }),
		JSON.stringify(h4.notifications));

	console.log('test: transport failures reach the user');
	const h5 = makeHarness({ setup_firewall: new Error('XHR request aborted by browser') });
	await h5.obj.render([{}, {}, { routes: [] }]);
	await h5.firewall()();
	check('the abort text is kept',
		h5.notifications.some(function(n) { return n.text.indexOf('XHR request aborted') !== -1; }),
		JSON.stringify(h5.notifications));

	console.log('test: a stale result from a previous run is not accepted');
	const h6 = makeHarness({
		setup_firewall: { success: true, changed_network: true, changed_firewall: false, job: 'running', run_id: 200 },
		get_firewall_status: { success: true, state: 'done', run_id: 100, message: '' }
	});
	await h6.obj.render([{}, {}, { routes: [] }]);
	await h6.firewall()();
	await settle();
	check('the job was actually polled',
		h6.calls.some(function(c) { return c.method === 'get_firewall_status'; }),
		JSON.stringify(h6.calls.map(function(c) { return c.method; })));
	check('the previous run outcome is ignored',
		!h6.notifications.some(function(n) { return n.text.indexOf('applied') !== -1; }),
		JSON.stringify(h6.notifications));

	console.log('test: an empty reply does not leak its format placeholder');
	const h7 = makeHarness({ setup_firewall: null });
	await h7.obj.render([{}, {}, { routes: [] }]);
	await h7.firewall()();
	check('no %s reaches the user',
		h7.notifications.every(function(n) { return n.text.indexOf('%s') === -1; }),
		JSON.stringify(h7.notifications));
	check('the prefix is not duplicated',
		h7.notifications.every(function(n) { return (n.text.match(/Failed to configure firewall/g) || []).length <= 1; }),
		JSON.stringify(h7.notifications));

	console.log('test: logout reports the backend error instead of success');
	const h8 = makeHarness({ do_logout: { error: 'Tailscale is not running. Cannot perform logout.' } });
	await h8.obj.render([{}, {}, { routes: [] }]);
	await h8.logout()();
	// the confirmation dialog is modal: walk its tree and press the
	// destructive button
	const press = async function(node) {
		if (!node || typeof node !== 'object') return false;
		if (node.tag === 'button' && node.attrs && node.attrs['class'] === 'cbi-button cbi-button-negative') {
			await node.attrs.click();
			return true;
		}
		for (const child of (node.children || [])) {
			if (await press(child)) return true;
		}
		return false;
	};
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
	// the logs tab writes into a DOM node; give the stub one so the text is
	// observable instead of silently skipped
	const logNode = { replaced: null, replaceChildren: function() { this.replaced = Array.prototype.slice.call(arguments); } };
	const h9 = makeHarness({ get_logs: { success: false, logs: [], error: 'logread unavailable' } });
	await h9.obj.render([{}, {}, { routes: [] }]);
	h9.setElement('tailscale_logs_display', logNode);
	await h9.refreshLogs()();
	await settle();
	const logText = textOf(logNode.replaced);
	check('the log error is surfaced',
		logText.indexOf('logread unavailable') !== -1,
		logText);

	console.log('test: unsaved changes are not silently ignored');
	const h10 = makeHarness({
		setup_firewall: { success: true, changed_network: true, changed_firewall: true, job: 'running', run_id: 5 }
	}, { pending: ['tailscale.settings.advertise_routes'] });
	await h10.obj.render([{}, {}, { routes: [] }]);
	await h10.firewall()();
	await settle();
	check('setup_firewall is not called while changes are staged',
		!h10.calls.some(function(c) { return c.method === 'setup_firewall'; }),
		JSON.stringify(h10.calls.map(function(c) { return c.method; })));
	check('the user is told to save first',
		h10.notifications.some(function(n) { return n.text.indexOf('unapplied changes') !== -1; }),
		JSON.stringify(h10.notifications));

	console.log('');
	console.log('passed: ' + passes + '  failed: ' + failures);
	process.exit(failures === 0 ? 0 : 1);
}

run().catch(function(e) {
	console.error(e);
	process.exit(1);
});

