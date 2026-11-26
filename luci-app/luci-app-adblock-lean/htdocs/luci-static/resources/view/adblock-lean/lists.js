'use strict';
// SPDX-License-Identifier: GPL-2.0-only
'require view';
'require rpc';
'require fs';
'require ui';

var callStatus = rpc.declare({ object: 'luci.adblock-lean', method: 'status', expect: { '': {} } });
var callSetLists = rpc.declare({ object: 'luci.adblock-lean', method: 'set_lists', params: [ 'key', 'value' ], expect: { '': {} } });
var callAction = rpc.declare({ object: 'luci.adblock-lean', method: 'action', params: [ 'name' ], expect: { '': {} } });

var ALLOWLIST = '/etc/adblock-lean/allowlist';
var BLOCKLIST = '/etc/adblock-lean/blocklist';

// Hagezi lists adblock-lean knows by short name. The full and plus variants
// need far more RAM: on a 512 MB router 'tif' (full) has run it out of memory.
var HAGEZI = [
	[ 'hagezi:light', _('Light: basic ad and tracker blocking') ],
	[ 'hagezi:multi', _('Multi (normal): all-round protection') ],
	[ 'hagezi:pro.mini', _('Pro mini') ],
	[ 'hagezi:pro', _('Pro: extended protection') ],
	[ 'hagezi:pro.plus.mini', _('Pro++ mini: aggressive, can break sign-in pop-ups') ],
	[ 'hagezi:tif.mini', _('Threat intelligence (mini)') ],
	[ 'hagezi:tif.medium', _('Threat intelligence (medium)') ],
	[ 'hagezi:doh', _('Encrypted DNS servers (stops devices bypassing the block)') ],
	[ 'hagezi:popupads', _('Pop-up ads') ],
	[ 'hagezi:fake', _('Fake shops and scams') ],
	[ 'hagezi:gambling.mini', _('Gambling (mini)') ]
];

function readFile(path) {
	return fs.read(path).catch(function() { return ''; });
}

return view.extend({
	load: function() {
		return Promise.all([ callStatus(), readFile(ALLOWLIST), readFile(BLOCKLIST) ]);
	},

	render: function(data) {
		var st = data[0], allow = data[1], block = data[2];
		var current = (st.raw_block_lists || '').split(/\s+/).filter(Boolean);
		var known = HAGEZI.map(function(h) { return h[0]; });
		var extra = current.filter(function(l) { return known.indexOf(l) < 0; });

		var boxes = HAGEZI.map(function(h) {
			return E('label', { 'style': 'display:block;margin:.2em 0' }, [
				E('input', { 'type': 'checkbox', 'class': 'abl-src', 'value': h[0], 'checked': current.indexOf(h[0]) >= 0 ? '' : null }),
				' ', E('code', {}, h[0]), ' - ', h[1]
			]);
		});

		return E([], [
			E('h2', {}, _('Adblock-lean: lists')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Blocklists')),
				E('p', { 'class': 'cbi-value-description' },
					_('Downloaded on every update. More lists means more memory: keep an eye on free RAM after a change.')),
				E('div', {}, boxes),
				E('p', {}, _('Other lists (oisd:, stevenblack: or http(s) URLs), separated by spaces:')),
				E('input', { 'id': 'abl-extra', 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%', 'value': extra.join(' ') })
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Your allowlist')),
				E('p', { 'class': 'cbi-value-description' }, _('One domain per line. Never blocked, including its subdomains.')),
				E('textarea', { 'id': 'abl-allow', 'class': 'cbi-input-textarea', 'style': 'width:100%;font-family:monospace', 'rows': 10, 'spellcheck': 'false' }, allow)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Your blocklist')),
				E('p', { 'class': 'cbi-value-description' }, _('One domain per line. Always blocked, including its subdomains.')),
				E('textarea', { 'id': 'abl-block', 'class': 'cbi-input-textarea', 'style': 'width:100%;font-family:monospace', 'rows': 10, 'spellcheck': 'false' }, block)
			])
		]);
	},

	collectLists: function() {
		var picked = Array.prototype.slice.call(document.querySelectorAll('.abl-src'))
			.filter(function(c) { return c.checked; }).map(function(c) { return c.value; });
		var extra = (document.getElementById('abl-extra').value || '').split(/\s+/).filter(Boolean);
		return picked.concat(extra).join(' ');
	},

	cleanDomains: function(text) {
		var bad = [];
		var lines = text.split(/\n/).map(function(l) { return l.trim().toLowerCase(); }).filter(function(l) {
			if (!l || l.charAt(0) === '#')
				return !!l;
			// Underscores occur in real hostnames and adblock-lean accepts them.
			if (!/^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)+$/.test(l)) {
				bad.push(l);
				return false;
			}
			return true;
		});
		return { text: lines.join('\n') + (lines.length ? '\n' : ''), bad: bad };
	},

	save: function(thenUpdate) {
		var self = this;
		var lists = this.collectLists();
		if (!lists)
			return Promise.reject(new Error(_('Pick at least one blocklist.')));
		var a = this.cleanDomains(document.getElementById('abl-allow').value);
		var b = this.cleanDomains(document.getElementById('abl-block').value);
		var bad = a.bad.concat(b.bad);
		if (bad.length)
			return Promise.reject(new Error(_('Not domain names: %s').format(bad.join(', '))));

		return callSetLists('raw_block_lists', lists).then(function(r) {
			if (!r.ok)
				throw new Error(r.error || _('Could not save the list choice'));
			return Promise.all([ fs.write(ALLOWLIST, a.text), fs.write(BLOCKLIST, b.text) ]);
		}).then(function() {
			if (!thenUpdate) {
				ui.addNotification(null, E('p', _('Saved. The change takes effect on the next list update.')), 'info');
				return;
			}
			return callAction('start').then(function(r) {
				if (!r.ok)
					throw new Error(r.error || _('Update did not start'));
				ui.addNotification(null, E('p', _('Saved. Lists are updating now: see the Overview page.')), 'info');
			});
		}).catch(function(e) {
			ui.addNotification(null, E('p', e.message), 'error');
		});
	},

	handleSave: function() {
		return this.save(false).catch(function(e) { ui.addNotification(null, E('p', e.message), 'error'); });
	},

	handleSaveApply: function() {
		return this.save(true).catch(function(e) { ui.addNotification(null, E('p', e.message), 'error'); });
	},

	handleReset: null
});
