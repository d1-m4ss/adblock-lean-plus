'use strict';
// SPDX-License-Identifier: GPL-2.0-only
// Modified in adblock-lean-plus (2026-11): see FORK-NOTES.md for the changes against upstream.
// Subscriptions page (adblock-lean-plus): add, switch off without deleting, delete; local allow/block lists.
'require view';
'require rpc';
'require ui';
'require dom';

var callGetSubs = rpc.declare({ object: 'luci.adblock-lean', method: 'get_subscriptions', expect: { '': {} } });
var callSetSubs = rpc.declare({ object: 'luci.adblock-lean', method: 'set_subscriptions', params: [ 'text' ], expect: { '': {} } });
var callGetLocal = rpc.declare({ object: 'luci.adblock-lean', method: 'get_local', params: [ 'kind' ], expect: { '': {} } });
var callSetLocal = rpc.declare({ object: 'luci.adblock-lean', method: 'set_local', params: [ 'kind', 'text', 'dry_run' ], expect: { '': {} } });
var callAction = rpc.declare({ object: 'luci.adblock-lean', method: 'action', params: [ 'name' ], expect: { '': {} } });
var callDetect = rpc.declare({ object: 'luci.adblock-lean', method: 'detect_format', params: [ 'url' ], expect: { '': {} } });
var callCatalog = rpc.declare({ object: 'luci.adblock-lean', method: 'get_catalog', expect: { '': {} } });

var AG = 'https://adguardteam.github.io/HostlistsRegistry/assets/';

// Ready-made subscriptions, grouped. HaGeZi lists use adblock-lean's short ids (plain-domain 'wildcard'
// lists, no conversion needed: faster updates than the AdGuard-syntax versions of the same lists).
// Browser-only lists (cosmetic rules, URL parameters, paths) are not offered: DNS can not apply them.
var PRESETS = [
	[ _('AdGuard'), [
		[ _('AdGuard DNS filter'), 'adguard', AG + 'filter_1.txt' ],
		[ _('AdGuard DNS Popup Hosts filter'), 'adguard', AG + 'filter_59.txt' ]
	] ],
	[ _('HaGeZi: ads, trackers'), [
		[ _('HaGeZi Light'), 'raw', 'hagezi:light' ],
		[ _('HaGeZi Multi (normal)'), 'raw', 'hagezi:multi' ],
		[ _('HaGeZi Pro mini'), 'raw', 'hagezi:pro.mini' ],
		[ _('HaGeZi Pro'), 'raw', 'hagezi:pro' ],
		[ _('HaGeZi Pro++'), 'raw', 'hagezi:pro.plus' ],
		[ _('HaGeZi Ultimate'), 'raw', 'hagezi:ultimate' ],
		[ _('HaGeZi Pop-up ads'), 'raw', 'hagezi:popupads' ],
		[ _('HaGeZi Native: Apple'), 'raw', 'hagezi:native.apple' ],
		[ _('HaGeZi Native: Samsung'), 'raw', 'hagezi:native.samsung' ],
		[ _('HaGeZi Native: Windows/Office'), 'raw', 'hagezi:native.winoffice' ],
		[ _('HaGeZi Native: Xiaomi'), 'raw', 'hagezi:native.xiaomi' ],
		[ _('HaGeZi Native: Amazon'), 'raw', 'hagezi:native.amazon' ]
	] ],
	[ _('Security'), [
		[ _('HaGeZi Threat Intelligence (mini)'), 'raw', 'hagezi:tif.mini' ],
		[ _('HaGeZi Threat Intelligence (medium)'), 'raw', 'hagezi:tif.medium' ],
		[ _('HaGeZi Threat Intelligence (full, ~1.1M domains, ~110 MB RAM)'), 'raw', 'hagezi:tif' ],
		[ _('HaGeZi Fake (scams, fake shops)'), 'raw', 'hagezi:fake' ],
		[ _('HaGeZi Encrypted DNS/VPN/Proxy bypass'), 'raw', 'hagezi:doh-vpn-proxy-bypass' ],
		[ _('HaGeZi Gambling'), 'raw', 'hagezi:gambling' ],
		[ _('HaGeZi High-Entropy NRDs, 7 days (~560k domains, yokoffing pick)'), 'adguard', 'https://raw.githubusercontent.com/hagezi/nrd/main/adblock/dga7.txt' ],
		[ _("Dandelion Sprout's Anti-Malware List (yokoffing pick)"), 'adguard', 'https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareAdGuardHome.txt' ]
	] ],
	[ _('All-purpose'), [
		[ _('HaGeZi combo ALT-SUGGESTED-MINI, top-N (Ultimate mini + TIF mini + more; yokoffing pick)'), 'adguard', 'https://raw.githubusercontent.com/cbuijs/hagezi/refs/heads/main/combo/alt-suggested-mini/domains.top-n.adblock' ],
		[ _('OISD big'), 'raw', 'oisd:big' ],
		[ _('StevenBlack hosts'), 'hosts', 'stevenblack:base' ]
	] ]
];

// text goes into .value, never through innerHTML
function textarea(id, text) {
	var ta = E('textarea', { 'id': id, 'class': 'cbi-input-textarea', 'style': 'width:100%;font-family:monospace', 'rows': 8, 'spellcheck': 'false' });
	ta.value = text || '';
	return ta;
}

function note(msg, type) {
	ui.addNotification(null, E('p', {}, document.createTextNode(msg)), type);
}

function allPresets() {
	return PRESETS.reduce(function(acc, g) { return acc.concat(g[1]); }, []);
}

var FORMATS = [
	[ 'adguard', _('AdGuard (||domain^)') ],
	[ 'raw', _('Domains') ],
	[ 'hosts', _('Hosts (0.0.0.0 domain)') ],
	[ 'raw_allow', _('Allowlist (domains)') ]
];

function presetName(source) {
	var all = allPresets(), m;
	for (var i = 0; i < all.length; i++)
		if (all[i][2] === source)
			return all[i][0];
	// AdGuard-syntax URL of a HaGeZi list that also has a short id
	m = source.match(/hagezi\/dns-blocklists(@latest|\/main|\/refs\/heads\/main)?\/adblock\/([a-z0-9.-]+)\.txt$/);
	if (m)
		for (var j = 0; j < all.length; j++)
			if (all[j][2] === 'hagezi:' + m[2])
				return all[j][0] + _(' (AdGuard syntax)');
	return null;
}

// what a list source and a list name may look like (the router checks the same)
var SOURCE = /^(?=.{1,500}$)(https?:\/\/[A-Za-z0-9._~:\/?%+@,-]+|(hagezi|oisd|stevenblack):[A-Za-z0-9._-]+)$/;
var NAME = /^[\p{L}\p{M}\p{N} .,:'()\/+&_\u2013-]{0,80}$/u;

function badSource(source) {
	return _('Not a usable list address: %s. Use an http(s) URL without spaces, quotes or characters such as $ ; & = ( ) *, or a short id like hagezi:pro.').format(source.slice(0, 120));
}

function badName() {
	return _('A list name may have up to 80 letters, digits, spaces and . , : \' ( ) / + & _ -');
}

var DOMAIN = /^(?=.{1,253}$)[a-z0-9_-]+(\.[a-z0-9_-]+)*$/;
var COMMENT = /^[\p{L}\p{M}\p{N} \t.,:'()\/+&_#*\u2013-]{0,200}$/u;

// number of the first line of a local list that the router would refuse, 0 if all are fine
function badLine(text) {
	var lines = text.split('\n');
	for (var i = 0; i < lines.length; i++) {
		var line = lines[i].replace(/\r$/, ''), c = line.indexOf('#'),
		    domain = (c < 0 ? line : line.slice(0, c)).trim().toLowerCase().replace(/\.$/, '').replace(/^\*\./, '');
		if ((domain && !DOMAIN.test(domain)) || (c >= 0 && !COMMENT.test(line.slice(c))))
			return i + 1;
	}
	return 0;
}

function badLocal(list, line) {
	return _('%s, line %d: write one domain per line (letters, digits, . _ -, optionally *.). A comment after # may have letters, digits, spaces and . , : \' ( ) / + & _ - # *').format(list, line);
}

// a name taken from a downloaded list: other characters become spaces
function cleanName(text) {
	return String(text || '').replace(/[^\p{L}\p{M}\p{N} .,:'()\/+&_\u2013-]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, 80).trim();
}

// show the automatic name (preset, catalog) as text, otherwise the field for the user's own name
function showName(tr) {
	var auto = listName(tr.querySelector('.abl-src').value.trim()),
	    label = tr.querySelector('.abl-name'), own = tr.querySelector('.abl-title');
	var useAuto = !!auto && !own.value.trim();
	label.textContent = useAuto ? auto : '';
	label.style.display = useAuto ? '' : 'none';
	own.style.display = useAuto ? 'none' : '';
}

// names of AdGuard's catalog, by download URL; filled once the catalog is loaded
var catalogNames = {};

function listName(source) {
	return presetName(source) || (Object.prototype.hasOwnProperty.call(catalogNames, source) ? catalogNames[source] : null);
}

function rememberNames(c) {
	(c.filters || []).forEach(function(f) { catalogNames[f.downloadUrl] = f.name; });
}

// Guess the format from the URL; null = keep what the user picked. 'dnsmasq' = not supported.
function guessFormat(url) {
	if (/\/dnsmasq\/|dnsmasq/i.test(url))
		return 'dnsmasq';
	if (/\/adblock\/|\.adblock$|adguard|filter_[0-9]+\.txt|ublock/i.test(url))
		return 'adguard';
	if (/\/wildcard\/|\/domains\/|onlydomains|domains\.txt$/i.test(url))
		return 'raw';
	if (/hosts/i.test(url))
		return 'hosts';
	return null;
}

return view.extend({
	load: function() {
		return Promise.all([ callGetSubs(), callGetLocal('allow'), callGetLocal('block') ]);
	},

	// show the names of listed subscriptions that are not presets (added from the catalog or by URL)
	loadNames: function() {
		return callCatalog().then(function(c) {
			rememberNames(c);
			Array.prototype.forEach.call(document.querySelectorAll('#abl-subs tr.abl-sub'), showName);
		});
	},

	subRow: function(sub) {
		var tr = E('tr', { 'class': 'tr abl-sub' }, [
			E('td', { 'class': 'td', 'style': 'width:3em;text-align:center' },
				E('input', { 'type': 'checkbox', 'class': 'abl-en', 'checked': sub.enabled ? '' : null,
					'title': _('Switched off subscriptions stay in the list but are not downloaded') })),
			E('td', { 'class': 'td' }, [
				// a text node: the name may come from the downloaded catalog
				E('div', { 'class': 'abl-name', 'style': 'font-weight:bold' }, ''),
				E('input', { 'type': 'text', 'class': 'cbi-input-text abl-title', 'style': 'width:100%;margin-bottom:.25em',
					'maxlength': 80, 'placeholder': _('Name (optional)'), 'value': sub.title || '' }),
				E('input', { 'type': 'text', 'class': 'cbi-input-text abl-src', 'style': 'width:100%', 'maxlength': 500, 'value': sub.source,
					'change': function(ev) { showName(ev.target.closest('tr')); } })
			]),
			E('td', { 'class': 'td', 'style': 'width:15em' },
				E('select', { 'class': 'cbi-input-select abl-fmt' }, FORMATS.map(function(f) {
					return E('option', { 'value': f[0], 'selected': f[0] === sub.format ? '' : null }, f[1]);
				}))),
			E('td', { 'class': 'td', 'style': 'width:6em' },
				E('button', { 'class': 'cbi-button cbi-button-remove', 'click': function(ev) {
					var row = ev.target.closest('tr');
					row.parentNode.removeChild(row);
				} }, _('Delete')))
		]);
		showName(tr);
		return tr;
	},

	addSub: function(format, source, title) {
		var tbody = document.getElementById('abl-subs');
		var exists = Array.prototype.some.call(tbody.querySelectorAll('.abl-src'), function(i) { return i.value.trim() === source; });
		if (exists) {
			note(_('Already in the list: %s').format(source), 'warning');
			return;
		}
		tbody.appendChild(this.subRow({ enabled: true, format: format, source: source, title: title }));
	},

	render: function(data) {
		var subs = data[0], allow = data[1], block = data[2];
		var self = this;

		if (subs.error)
			return E('div', { 'class': 'alert-message warning' }, document.createTextNode(subs.error));

		var idx = 0;
		var presetSel = E('select', { 'class': 'cbi-input-select', 'id': 'abl-preset' }, [ E('option', { 'value': '' }, _('Add a ready-made list…')) ].concat(
			PRESETS.map(function(g) {
				return E('optgroup', { 'label': g[0] }, g[1].map(function(p) { return E('option', { 'value': idx++ }, p[0]); }));
			})));
		var customFmt = E('select', { 'class': 'cbi-input-select', 'id': 'abl-custom-fmt' }, FORMATS.map(function(f) {
			return E('option', { 'value': f[0] }, f[1]);
		}));
		var customSrc = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'id': 'abl-custom-src', 'maxlength': 500, 'placeholder': 'https://…', 'style': 'min-width:24em;flex:1' });
		var customName = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'id': 'abl-custom-name', 'maxlength': 80, 'placeholder': _('Name (optional)') });

		// after the page is shown: the router may have to download the catalog first
		if ((subs.subscriptions || []).some(function(s) { return /^https?:/.test(s.source) && !presetName(s.source); }))
			window.setTimeout(function() { self.loadNames(); }, 0);

		return E([], [
			E('h2', {}, _('Adblock-lean-plus: subscriptions')),
			E('div', { 'class': 'cbi-section' }, [
				E('p', { 'class': 'cbi-value-description' },
					_('Tick to use a list, untick to switch it off without deleting it. Changes take effect on the next list update (Save & Apply runs it now). More lists means more memory for dnsmasq. The format of a URL is guessed when you add it; check it before saving.')),
				E('table', { 'class': 'table' }, [
					E('thead', {}, E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('On')),
						E('th', { 'class': 'th' }, _('List')),
						E('th', { 'class': 'th' }, _('Format')),
						E('th', { 'class': 'th' }, '')
					])),
					E('tbody', { 'id': 'abl-subs' }, (subs.subscriptions || []).map(function(s) { return self.subRow(s); }))
				]),
				E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;align-items:center;margin-top:.8em' }, [
					presetSel,
					E('button', { 'class': 'cbi-button cbi-button-add', 'click': function() {
						var i = document.getElementById('abl-preset').value;
						if (i === '') return;
						var p = allPresets()[+i];
						self.addSub(p[1], p[2]);
					} }, _('Add')),
					E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(self, 'handleCatalog') }, _('AdGuard catalog…'))
				]),
				E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;align-items:center;margin-top:.5em' }, [
					customName, customSrc, customFmt,
					E('button', { 'class': 'cbi-button cbi-button-add', 'click': ui.createHandlerFn(self, 'handleAddUrl') }, _('Add URL'))
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Your allowlist')),
				E('p', { 'class': 'cbi-value-description' }, _('One domain per line, # starts a comment. Never blocked, including its subdomains.')),
				textarea('abl-allow', allow.text)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Your blocklist')),
				E('p', { 'class': 'cbi-value-description' }, _('One domain per line, # starts a comment. Always blocked, including its subdomains (AdGuard-list exceptions never override it).')),
				textarea('abl-block', block.text)
			])
		]);
	},

	// The router downloads the first 64 KB and counts the rule syntax; if that fails, the URL is used.
	handleAddUrl: function() {
		var self = this, input = document.getElementById('abl-custom-src'), src = input.value.trim();
		if (!src)
			return;
		if (!SOURCE.test(src))
			return note(badSource(src), 'error');
		if (!NAME.test(document.getElementById('abl-custom-name').value.trim()))
			return note(badName(), 'error');
		var DNSMASQ = _('dnsmasq-format lists are not supported: adblock-lean builds the dnsmasq format itself. Use the "wildcard"/"domains" (plain domains) or "adblock" (AdGuard syntax) version of the same list.');
		return callDetect(src).then(function(r) {
			var fmt;
			if (r.ok) {
				fmt = r.format;
				var usable = r.rules - r.unusable - r.dnsmasq;
				if (fmt !== 'dnsmasq' && r.unusable > usable)
					note(_('Only %d of the first %d rules can be used by DNS filtering; the rest are browser rules (cosmetic, URL parameters, paths). This looks like a browser (uBlock Origin) list.').format(usable, r.rules), 'warning');
			} else {
				fmt = guessFormat(src);
				note(_('Could not check the list (%s); the format is guessed from the URL.').format(r.error || '?'), 'warning');
			}
			if (fmt === 'dnsmasq') {
				note(DNSMASQ, 'warning');
				return;
			}
			if (fmt === 'none') {
				note(_('None of the first %d rules can be used by DNS filtering: this is a browser-only list. Not added.').format(r.rules), 'warning');
				return;
			}
			if (fmt)
				document.getElementById('abl-custom-fmt').value = fmt;
			// the user's name; else the automatic one (preset, catalog) or the title from the list itself
			var nameInput = document.getElementById('abl-custom-name'),
			    name = nameInput.value.trim() || (listName(src) ? '' : cleanName(r.ok && r.title));
			self.addSub(document.getElementById('abl-custom-fmt').value, src, name);
			input.value = '';
			nameInput.value = '';
		});
	},

	// AdGuard's catalog, the same lists AdGuard Home offers; all of them are AdGuard syntax
	handleCatalog: function() {
		var self = this;
		var have = Array.prototype.map.call(document.querySelectorAll('#abl-subs .abl-src'), function(i) { return i.value.trim(); });
		return callCatalog().then(function(c) {
			if (!c.filters) {
				note(c.error || _('Could not load the AdGuard list catalog'), 'error');
				return;
			}
			rememberNames(c);
			var groups = (c.groups || []).slice().sort(function(a, b) { return a.displayNumber - b.displayNumber; });
			var body = groups.map(function(g) {
				var items = c.filters.filter(function(f) { return f.groupId === g.groupId && !f.deprecated; })
					.sort(function(a, b) { return a.displayNumber - b.displayNumber; });
				return E('div', { 'style': 'margin-bottom:1em' }, [
					E('h4', {}, document.createTextNode(g.groupName)),
					E('div', {}, items.map(function(f) {
						var on = have.indexOf(f.downloadUrl) >= 0;
						return E('label', { 'style': 'display:block;margin:.25em 0', 'title': f.description || '' }, [
							E('input', { 'type': 'checkbox', 'class': 'abl-cat', 'value': f.downloadUrl,
								'checked': on ? '' : null, 'disabled': on ? '' : null }),
							' ', document.createTextNode(f.name)
						]);
					}))
				]);
			});
			ui.showModal(_('AdGuard list catalog'), [
				E('p', { 'class': 'cbi-value-description' }, _('The lists AdGuard Home offers. Hover a name for its description. Lists already subscribed are ticked.')),
				E('div', { 'style': 'max-height:60vh;overflow:auto' }, body),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
					E('button', { 'class': 'cbi-button cbi-button-positive', 'click': function() {
						Array.prototype.forEach.call(document.querySelectorAll('.abl-cat'), function(cb) {
							if (cb.checked && !cb.disabled)
								self.addSub('adguard', cb.value);
						});
						ui.hideModal();
					} }, _('Add selected'))
				])
			]);
		});
	},

	collectSubs: function() {
		return Array.prototype.map.call(document.querySelectorAll('#abl-subs tr.abl-sub'), function(tr) {
			var name = tr.querySelector('.abl-title').value.replace(/\s+/g, ' ').trim();
			return [ tr.querySelector('.abl-en').checked ? '1' : '0', tr.querySelector('.abl-fmt').value,
				tr.querySelector('.abl-src').value.trim() ].concat(name ? [ name ] : []).join(' ');
		}).join('\n');
	},

	// the first row with a source or name the router would refuse
	invalidRow: function() {
		var rows = document.querySelectorAll('#abl-subs tr.abl-sub');
		for (var i = 0; i < rows.length; i++) {
			var src = rows[i].querySelector('.abl-src').value.trim();
			if (!SOURCE.test(src))
				return badSource(src);
			if (!NAME.test(rows[i].querySelector('.abl-title').value.replace(/\s+/g, ' ').trim()))
				return badName();
		}
		return null;
	},

	save: function(thenUpdate) {
		var invalid = this.invalidRow();
		if (invalid)
			return Promise.reject(new Error(invalid));
		var subs = this.collectSubs(),
		    allow = document.getElementById('abl-allow').value,
		    block = document.getElementById('abl-block').value,
		    allowLine = badLine(allow), blockLine = badLine(block);
		if (allowLine || blockLine)
			return Promise.reject(new Error(allowLine ? badLocal(_('Allowlist'), allowLine) : badLocal(_('Blocklist'), blockLine)));
		// validate both local lists first, so a bad line does not leave a half-saved page
		return Promise.all([ callSetLocal('allow', allow, 1), callSetLocal('block', block, 1) ]).then(function(r) {
			if (!r[0].ok)
				throw new Error(_('Allowlist, nothing saved: %s').format(r[0].error || '?'));
			if (!r[1].ok)
				throw new Error(_('Blocklist, nothing saved: %s').format(r[1].error || '?'));
			return callSetSubs(subs);
		}).then(function(r) {
			if (!r.ok)
				throw new Error(_('Subscriptions, nothing saved: %s').format(r.error || '?'));
			return callSetLocal('allow', allow, 0);
		}).then(function(r) {
			if (!r.ok)
				throw new Error(_('Subscriptions saved, allowlist not: %s').format(r.error || '?'));
			return callSetLocal('block', block, 0);
		}).then(function(r) {
			if (!r.ok)
				throw new Error(_('Subscriptions and allowlist saved, blocklist not: %s').format(r.error || '?'));
			if (!thenUpdate) {
				note(_('Saved. The change takes effect on the next list update.'), 'info');
				return;
			}
			return callAction('start').then(function(r) {
				if (!r.ok)
					throw new Error(r.error || _('Update did not start'));
				note(_('Saved. Lists are updating now: see the Overview page.'), 'info');
			});
		});
	},

	handleSave: function() {
		return this.save(false).catch(function(e) { note(e.message, 'error'); });
	},

	handleSaveApply: function() {
		return this.save(true).catch(function(e) { note(e.message, 'error'); });
	},

	handleReset: null
});
