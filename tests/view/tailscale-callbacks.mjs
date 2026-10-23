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
	if (typeof attrs !== 'object' || attrs === null || Array.isArray(attrs)) {
		children = attrs;
		attrs = {};
	}
	if (typeof children === 'string' || typeof children === 'number') children = [ String(children) ];
	return { tag: tag, attrs: attrs || {}, children: Array.isArray(children) ? children : [] };
}

function makeHarness(responses) {
	const notifications = [];
	const calls = [];
	const buttons = [];

	function makeOption() {
		const self = {
			taboption: function() { return self; },
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
				buttons.push(fn);
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
		showModal: function() {},
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
		changes: function() { return []; },
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
		{ getElementById: function() { return null; }, createElement: function() { return {}; } },
		{ setTimeout: function(fn, ms) { return setTimeout(fn, Math.min(ms, 5)); } },
		{ getItem: function() { return null; }, setItem: function() {} }
	);

	return {
		obj: obj,
		calls: calls,
		notifications: notifications,
		buttons: buttons,
		// the firewall button is the only one whose callback is assigned via a
		// form.Button named _setup_firewall; grab it by triggering render and
		// taking the callback registered right after the mobile-friendly ones
		firewall: function() {
			return buttons[0];
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

	console.log('');
	console.log('passed: ' + passes + '  failed: ' + failures);
	process.exit(failures === 0 ? 0 : 1);
}

run().catch(function(e) {
	console.error(e);
	process.exit(1);
});
