'use strict';
// SPDX-License-Identifier: GPL-2.0-only
// Modified in adblock-lean-plus (2026-11): see FORK-NOTES.md for the changes against upstream.
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';
'require view.adblock-lean.names as listnames';

var callStatus = rpc.declare({ object: 'luci.adblock-lean', method: 'status', expect: { '': {} } });
var callAction = rpc.declare({ object: 'luci.adblock-lean', method: 'action', params: [ 'name' ], expect: { '': {} } });
var callCheck = rpc.declare({ object: 'luci.adblock-lean', method: 'check', params: [ 'domain' ], expect: { '': {} } });
var callSetSchedule = rpc.declare({ object: 'luci.adblock-lean', method: 'set_schedule', params: [ 'schedule' ], expect: { '': {} } });
var callGetSubs = rpc.declare({ object: 'luci.adblock-lean', method: 'get_subscriptions', expect: { '': {} } });
var callSetSubs = rpc.declare({ object: 'luci.adblock-lean', method: 'set_subscriptions', params: [ 'text', 'dry_run' ], expect: { '': {} } });
var callCatalog = rpc.declare({ object: 'luci.adblock-lean', method: 'get_catalog', expect: { '': {} } });
var callGetLocal = rpc.declare({ object: 'luci.adblock-lean', method: 'get_local', params: [ 'kind' ], expect: { '': {} } });
var callSetLocal = rpc.declare({ object: 'luci.adblock-lean', method: 'set_local', params: [ 'kind', 'text', 'dry_run' ], expect: { '': {} } });

var BACKUP_FORMAT = 'adblock-lean-plus-backup';
// the schedules set_schedule accepts; others (set by hand) are saved in a backup but not restored
var DAILY = /^(disable|([0-9]|[0-5][0-9]) ([0-9]|[01][0-9]|2[0-3]) \* \* \*)$/;

// what a list source and a list name may look like (the router checks the same)
var SOURCE = /^(?=.{1,500}$)(https?:\/\/[A-Za-z0-9._~:\/?%+@,-]+|(hagezi|oisd|stevenblack):[A-Za-z0-9._-]+)$/;
var NAME = /^[\p{L}\p{M}\p{N} .,:'()\/+&_\u2013-]{0,80}$/u;

// settings from a backup file's text, or { error: ... }
function parseBackup(text) {
	var d;
	try { d = JSON.parse(text); }
	catch (e) { return { error: _('This is not a JSON file.') }; }
	if (!d || d.format !== BACKUP_FORMAT)
		return { error: _('This is not an adblock-lean-plus backup.') };
	if (d.version !== 1)
		return { error: _('This backup version is not supported.') };
	var okSub = function(s) {
		return s && typeof s.enabled === 'boolean' && /^[a-z_]+$/.test(s.format) && typeof s.source === 'string' && SOURCE.test(s.source) &&
			(s.title === undefined || (typeof s.title === 'string' && NAME.test(s.title)));
	};
	if (!Array.isArray(d.subscriptions) || !d.subscriptions.every(okSub) || typeof d.allowlist !== 'string' ||
	    typeof d.blocklist !== 'string' || typeof d.update_schedule !== 'string' || typeof d.start_at_boot !== 'boolean')
		return { error: _('The backup file is incomplete or damaged.') };
	return d;
}

function note(message, kind) {
	ui.addNotification(null, E('p', {}, document.createTextNode(message)), kind);
}

// rejects with the router's message when a call did not succeed
function must(what) {
	return function(r) {
		if (!r || !r.ok)
			throw new Error(what + ': ' + ((r && r.error) || _('failed')));
		return r;
	};
}

function fmtInt(n) {
	return (+n || 0).toLocaleString();
}

function fmtAge(ts, now) {
	if (!ts)
		return _('never');
	var s = Math.max(0, now - ts), d = new Date(ts * 1000);
	var ago = s < 3600 ? _('%d min ago').format(Math.floor(s / 60))
		: s < 172800 ? _('%d h ago').format(Math.floor(s / 3600))
		: _('%d days ago').format(Math.floor(s / 86400));
	return '%s (%s)'.format(d.toLocaleString(), ago);
}

function stateBadge(st) {
	var busy = st.state.indexOf('busy:') === 0;
	var label = busy ? _('Working') : { active: _('Active'), paused: _('Paused'), stopped: _('Stopped') }[st.state] || st.state;
	var colour = busy ? '#c07a00' : { active: '#2e7d32', paused: '#c07a00', stopped: '#c62828' }[st.state] || '#666';
	return E('span', { 'style': 'display:inline-block;padding:.15em .6em;border-radius:1em;color:#fff;background:%s'.format(colour) }, label);
}

// kB (as reported by the router) to a short human figure
function fmtKB(kb) {
	kb = +kb || 0;
	if (kb >= 1048576)
		return (kb / 1048576).toFixed(2) + ' GB';
	return (kb >= 10240 ? Math.round(kb / 1024) : (kb / 1024).toFixed(1)) + ' MB';
}

// one bar: [ [ kB, colour, label ] ... ] out of total kB, with a legend
function usageBar(parts, total) {
	var bar = parts.map(function(p) {
		var width = (total ? Math.min(100, 100 * p[0] / total) : 0).toFixed(2) + '%';
		return E('div', { 'style': 'width:' + width + ';background:' + p[1] });
	});
	var legend = parts.map(function(p) {
		return E('span', { 'style': 'white-space:nowrap' }, [
			E('span', { 'style': 'display:inline-block;width:.8em;height:.8em;margin-right:.35em;border:1px solid #999;background:%s'.format(p[1]) }),
			'%s: %s'.format(p[2], fmtKB(p[0]))
		]);
	});
	return E('div', {}, [
		E('div', { 'style': 'display:flex;height:1em;border:1px solid #999;border-radius:.25em;overflow:hidden' }, bar),
		E('div', { 'style': 'display:flex;gap:1.2em;flex-wrap:wrap;margin-top:.35em' }, legend)
	]);
}

// a list address as a key: short ids are case-insensitive
function listKey(source) {
	return /^https?:/i.test(source) ? source : source.toLowerCase();
}

function row(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, label),
		E('td', { 'class': 'td left' }, value)
	]);
}

return view.extend({
	load: function() {
		return callStatus();
	},

	renderStatus: function(st) {
		var busy = st.state.indexOf('busy:') === 0;
		var rows = [
			row(_('Status'), [ stateBadge(st), busy ? E('em', { 'style': 'margin-left:.6em' }, document.createTextNode(st.state.substr(5))) : '' ]),
			row(_('Domains blocked'), st.state === 'active' ? E('strong', {}, fmtInt(st.entries)) : '-'),
			row(_('Lists last updated'), fmtAge(st.updated, st.now)),
			row(_('Last update took'), st.last_duration || '-'),
			row(_('Automatic update'), this.renderSchedule(st)),
			row(_('Start at boot'), st.enabled ? (st.early_boot ? _('Yes, filtering from the dnsmasq start') : _('Yes')) : _('No')),
			row(_('dnsmasq'), st.dnsmasq_running ? _('running') : E('strong', { 'style': 'color:#c62828' }, _('not running'))),
			row(_('adblock-lean-plus version'), (st.version || '?') + (st.blockset ? ' (blockset ' + st.blockset + ')' : ''))
		];
		return E('table', { 'class': 'table' }, rows);
	},

	// memory and flash the blocker needs, and what the router has left
	renderResources: function(st) {
		var r = st.resources || {};
		if (!r.mem_total)
			return E('p', { 'class': 'cbi-value-description' }, _('No figures available.'));
		var own = (+r.dnsmasq_rss || 0) + (+r.doh_rss || 0);
		var available = +r.mem_available || 0;
		var other = Math.max(0, r.mem_total - available - own);
		var rows = [
			row(_('Memory'), usageBar([
				[ own, '#1976d2', _('DNS and blocking') ],
				[ other, '#9e9e9e', _('rest of the system') ],
				[ available, 'transparent', _('available') ]
			], +r.mem_total)),
			row(_('dnsmasq, blocklist included'), fmtKB(r.dnsmasq_rss)),
			row(_('DoH proxies'), r.doh_rss ? fmtKB(r.doh_rss) : _('not running')),
			row(_('Together'), E('strong', {}, _('%s of %s').format(fmtKB(own), fmtKB(r.mem_total)) + ' (' + Math.round(100 * own / r.mem_total) + '%)')),
			row(_('Blocklist file'), r.blockset_size ? _('%s, compressed, %s').format(fmtKB(r.blockset_size), r.blockset_on_flash ? _('on flash') : _('in RAM')) : '-')
		];
		if (r.flash_total)
			rows.push(row(_('Free flash space'), _('%s of %s').format(fmtKB(r.flash_free), fmtKB(r.flash_total))));
		return E('table', { 'class': 'table' }, rows);
	},

	// daily update at a chosen hour; adblock-lean adds a random delay of up to 60 min
	renderSchedule: function(st) {
		var cur = st.upd_schedule || 'disable';
		var m = cur.match(/^(\d+) (\d+) \* \* \*$/);
		// the status table is re-rendered by the poll: keep a choice the user has not applied yet
		var pick = this.schedulePick || cur;
		var self = this;
		var values = [ 'disable' ];
		for (var h = 0; h < 24; h++)
			values.push('0 ' + h + ' * * *');
		var opts = values.map(function(v) {
			return E('option', { 'value': v, 'selected': pick === v ? '' : null },
				v === 'disable' ? _('Off') : _('Daily at %02d:00').format(+v.split(' ')[1]));
		});
		// a schedule set elsewhere (other minute, several hours...) is shown as it is, not rounded or lost
		if (values.indexOf(cur) < 0)
			opts.unshift(E('option', { 'value': cur, 'selected': pick === cur ? '' : null }, _('Custom: %s').format(cur)));
		var sel = E('select', { 'class': 'cbi-input-select', 'id': 'abl-schedule',
			'change': function(ev) { self.schedulePick = ev.target.value; } }, opts);
		var cur_h = m ? +m[2] : -1;
		this.scheduleCurrent = cur;
		var note = st.cron ? _('cron: %s, plus a random delay of up to 60 min').format(st.cron)
			: (cur_h < 0 ? _('lists are only updated by hand') : st.enabled ? _('set, but no cron job yet') : _('starts when start at boot is switched on'));
		return E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;align-items:center' }, [
			sel,
			E('button', { 'class': 'cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, 'handleSchedule') }, _('Apply')),
			E('span', { 'class': 'cbi-value-description' }, document.createTextNode(note))
		]);
	},

	handleSchedule: function() {
		var self = this, v = document.getElementById('abl-schedule').value;
		if (v === this.scheduleCurrent) {
			this.schedulePick = null;
			ui.addNotification(null, E('p', {}, document.createTextNode(_('The schedule is unchanged.'))), 'info');
			return;
		}
		return callSetSchedule(v).then(function(r) {
			self.schedulePick = null;
			ui.addNotification(null, E('p', {}, document.createTextNode(r.ok ? _('Update schedule saved.') : (r.error || _('Could not save the schedule')))), r.ok ? 'info' : 'error');
			return self.refresh();
		});
	},

	// the names the user gave to lists, then those of AdGuard's catalog; shown once loaded
	loadNames: function() {
		var self = this;
		return callGetSubs().then(function(r) {
			var own = Object.create(null), allow = Object.create(null);
			(r.subscriptions || []).forEach(function(s) {
				if (s.title) own[s.source] = s.title;
				if (s.format === 'raw_allow') allow[listKey(s.source)] = true;
			});
			self.ownNames = own;
			self.allowSources = allow;
			var unnamed = ((self.status || {}).lists || []).some(function(l) {
				return /^https?:/.test(l.name) && !own[l.name] && !listnames.name(l.name);
			});
			if (unnamed)
				return callCatalog().then(function(c) { listnames.remember(c); });
		}).then(function() {
			var box = document.getElementById('abl-lists');
			if (box && self.status)
				dom.content(box, self.renderLists(self.status));
		}).catch(function() {
			// without the names the table still shows the addresses
		});
	},

	// every list the same way: its name in bold and its address (or file) below
	listCell: function(source) {
		var local = source.indexOf('/') === 0, name;
		if (local)
			name = /\/local-allowlist/.test(source) ? _('Your allowlist') : /\/local-blocklist/.test(source) ? _('Your blocklist') : _('Local list');
		else
			name = (this.ownNames && this.ownNames[source]) || listnames.name(source);
		// text nodes: names and addresses come from files and downloads
		return E('td', { 'class': 'td', 'style': 'word-break:break-all' }, [
			name ? E('div', {}, E('strong', {}, document.createTextNode(name))) : '',
			E('div', { 'style': name ? 'font-size:90%;opacity:.75' : '' }, document.createTextNode(source))
		]);
	},

	renderLists: function(st) {
		if (!st.lists || !st.lists.length)
			return E('p', { 'class': 'cbi-value-description' }, _('No per-list figures yet. They appear after the next list update.'));

		var rows = [ E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('List')),
			E('th', { 'class': 'th right' }, _('Entries')),
			E('th', { 'class': 'th right' }, _('Download size'))
		]) ];
		var self = this;
		st.lists.forEach(function(l) {
			rows.push(E('tr', { 'class': 'tr' }, [
				self.listCell(l.name),
				E('td', { 'class': 'td right' }, fmtInt(l.lines)),
				E('td', { 'class': 'td right' }, l.size.replace(/\s+/g, ' '))
			]));
		});
		// how much the block lists overlap. The total below counts the allow rules too, so:
		// lists together - removed + allow rules = total. Not shown in allowlist-only mode (block lists are
		// then dropped almost entirely) nor before it is known which lists are allowlists.
		var together = st.lists.reduce(function(sum, l) {
			var allow = /\/local-allowlist/.test(l.name) || (self.allowSources && self.allowSources[listKey(l.name)]);
			return allow ? sum : sum + (+l.lines || 0);
		}, 0);
		var allowRules = +st.allow_entries || 0, blocked = st.entries - allowRules, removed = together - blocked;
		var figure = function(label, value) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, label),
				E('td', { 'class': 'td right' }, value),
				E('td', { 'class': 'td' }, '')
			]);
		};
		if (st.state === 'active' && st.whitelist_mode !== '1' && st.allow_entries !== undefined && self.allowSources &&
		    blocked > 0 && removed > 0) {
			rows.push(figure(_('All block lists together'), fmtInt(together)));
			rows.push(figure(_('Removed: duplicates and allowed domains'),
				'\u2212' + fmtInt(removed) + ' (' + Math.round(100 * removed / together) + '%)'));
			if (allowRules)
				rows.push(figure(_('Allow rules loaded as well'), '+' + fmtInt(allowRules)));
		}
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, E('strong', {}, _('In dnsmasq after merging duplicates'))),
			E('td', { 'class': 'td right' }, E('strong', {}, fmtInt(st.entries))),
			E('td', { 'class': 'td' }, '')
		]));
		return E([], [
			E('table', { 'class': 'table' }, rows),
			E('p', { 'class': 'cbi-value-description' },
				_('From the list update at %s.').format(new Date(st.lists_at * 1000).toLocaleString()))
		]);
	},

	renderButtons: function(st) {
		var busy = st.state.indexOf('busy:') === 0;
		var self = this;
		function btn(label, action, cls, title) {
			return E('button', {
				'class': 'cbi-button ' + cls,
				'title': title || '',
				'disabled': busy ? '' : null,
				'click': ui.createHandlerFn(self, 'handleAction', action)
			}, label);
		}
		var b = [];
		b.push(btn(_('Update lists now'), 'start', 'cbi-button-apply', _('Download every list again and reload dnsmasq')));
		if (st.state === 'active') {
			b.push(btn(_('Pause'), 'pause', 'cbi-button-neutral', _('Stop blocking, keep the blockset for a quick resume')));
			b.push(btn(_('Stop'), 'stop', 'cbi-button-negative', _('Stop blocking and unload the lists')));
		}
		if (st.state === 'paused') {
			b.push(btn(_('Resume'), 'resume', 'cbi-button-positive', _('Load the paused blockset again')));
			b.push(btn(_('Stop'), 'stop', 'cbi-button-negative', _('Unload the paused blockset')));
		}
		b.push(st.enabled ? btn(_('Disable at boot'), 'disable', 'cbi-button-neutral')
			: btn(_('Enable at boot'), 'enable', 'cbi-button-positive'));
		return E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap' }, b);
	},

	// one file with the lists, local allow/block lists, update schedule and start at boot
	handleBackup: function() {
		return Promise.all([ callStatus(), callGetSubs(), callGetLocal('allow'), callGetLocal('block') ]).then(function(r) {
			var st = r[0], subs = r[1], allow = r[2], block = r[3];
			if (!subs.subscriptions || typeof allow.text !== 'string' || typeof block.text !== 'string')
				throw new Error(subs.error || allow.error || block.error || _('could not read the settings'));
			var now = new Date();
			var data = {
				'format': BACKUP_FORMAT,
				'version': 1,
				'created': now.toISOString(),
				'subscriptions': subs.subscriptions.map(function(s) {
					var out = { 'enabled': !!s.enabled, 'format': s.format, 'source': s.source };
					if (s.title)
						out.title = s.title;
					return out;
				}),
				'update_schedule': st.upd_schedule || 'disable',
				'start_at_boot': !!st.enabled,
				'allowlist': allow.text,
				'blocklist': block.text
			};
			var url = URL.createObjectURL(new Blob([ JSON.stringify(data, null, 2) + '\n' ], { 'type': 'application/json' }));
			var a = E('a', { 'href': url, 'download': 'adblock-lean-plus-' + now.toISOString().slice(0, 10) + '.json', 'style': 'display:none' });
			document.body.appendChild(a);
			a.click();
			window.setTimeout(function() { document.body.removeChild(a); URL.revokeObjectURL(url); }, 1000);
		}).catch(function(e) { note(_('Backup failed') + ': ' + e.message, 'error'); });
	},

	handleImportFile: function(ev) {
		var self = this, input = ev.target, file = input.files && input.files[0];
		if (!file)
			return;
		var reader = new FileReader();
		reader.onload = function() {
			// the same file can be picked again
			input.value = '';
			var d = parseBackup(String(reader.result));
			if (d.error)
				return note(d.error, 'error');
			self.confirmImport(d);
		};
		reader.onerror = function() {
			input.value = '';
			note(_('The file could not be read.'), 'error');
		};
		reader.readAsText(file);
	},

	confirmImport: function(d) {
		var self = this;
		var on = d.subscriptions.filter(function(s) { return s.enabled; }).length;
		var count = function(text) { return text.split('\n').filter(function(l) { return /^\s*[^#\s]/.test(l); }).length; };
		var items = [
			_('Lists: %d, enabled: %d').format(d.subscriptions.length, on),
			_('Allowlist domains: %d').format(count(d.allowlist)),
			_('Blocklist domains: %d').format(count(d.blocklist)),
			_('Automatic update: %s').format(d.update_schedule) + (DAILY.test(d.update_schedule) ? '' : ' (' + _('custom schedule, will not be restored') + ')'),
			_('Start at boot: %s').format(d.start_at_boot ? _('Yes') : _('No'))
		];
		ui.showModal(_('Import settings'), [
			E('p', {}, _('The current lists, allowlist and blocklist will be replaced by those in the file.')),
			E('ul', {}, items.map(function(t) { return E('li', {}, document.createTextNode(t)); })),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'cbi-button cbi-button-apply', 'click': ui.createHandlerFn(self, 'applyImport', d) }, _('Import'))
			])
		]);
	},

	// everything is validated by the router first, then written step by step
	applyImport: function(d) {
		var self = this, done = [], st;
		var subs = d.subscriptions.map(function(s) { return (s.enabled ? '1 ' : '0 ') + s.format + ' ' + s.source + (s.title ? ' ' + s.title : ''); }).join('\n');
		var step = function(label, call) {
			return function() { return call().then(must(label)).then(function() { done.push(label); }); };
		};
		return callStatus().then(function(r) {
			st = r;
			if (st.state.indexOf('busy:') === 0)
				throw new Error(_('adblock-lean-plus is busy, try again when it has finished'));
			if (!d.start_at_boot && st.enabled && !confirm(_('The backup has "Start at boot" off. Switching it off also stops blocking now. Continue?')))
				throw new Error(_('cancelled'));
			return callSetSubs(subs, 1).then(must(_('Lists')));
		})
		.then(function() { return callSetLocal('allow', d.allowlist, 1).then(must(_('Allowlist'))); })
		.then(function() { return callSetLocal('block', d.blocklist, 1).then(must(_('Blocklist'))); })
		.then(step(_('Lists'), function() { return callSetSubs(subs, 0); }))
		.then(step(_('Allowlist'), function() { return callSetLocal('allow', d.allowlist, 0); }))
		.then(step(_('Blocklist'), function() { return callSetLocal('block', d.blocklist, 0); }))
		.then(function() {
			if (DAILY.test(d.update_schedule) && d.update_schedule !== (st.upd_schedule || 'disable'))
				return step(_('Automatic update'), function() { return callSetSchedule(d.update_schedule); })();
		})
		.then(function() {
			if (d.start_at_boot !== !!st.enabled)
				return step(_('Start at boot'), function() { return callAction(d.start_at_boot ? 'enable' : 'disable'); })();
		})
		.then(function() {
			self.schedulePick = null;
			self.loadNames();
			ui.showModal(_('Settings imported'), [
				E('p', {}, _('The lists take effect with the next list update.')),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Later')), ' ',
					E('button', { 'class': 'cbi-button cbi-button-apply', 'click': ui.createHandlerFn(self, function() {
						ui.hideModal();
						return self.handleAction('start');
					}) }, _('Update lists now'))
				])
			]);
			return self.refresh();
		})
		.catch(function(e) {
			ui.hideModal();
			note(_('Import failed') + ' - ' + e.message + '. ' +
				(done.length ? _('Already changed: %s').format(done.join(', ')) : _('Nothing was changed.')), 'error');
			return self.refresh();
		});
	},

	handleAction: function(action) {
		var self = this;
		if (action === 'stop' && !confirm(_('Stop adblock-lean-plus? Ads will not be blocked until it is started again.')))
			return;
		return callAction(action).then(function(r) {
			if (!r.ok)
				ui.addNotification(null, E('p', {}, document.createTextNode(r.error || _('Action failed'))), 'error');
			return self.refresh();
		});
	},

	handleCheck: function(ev) {
		var input = document.getElementById('abl-check-domain'),
		    out = document.getElementById('abl-check-result');
		var domain = (input.value || '').trim().toLowerCase().replace(/\.$/, '');
		if (!domain)
			return;
		if (!/^(?=.{1,253}$)[a-z0-9_-]+(\.[a-z0-9_-]+)*$/.test(domain)) {
			dom.content(out, E('span', { 'style': 'color:#c62828' },
				_('Enter a domain name such as ads.example.com: letters, digits, dots, _ and - (no http:// and no path).')));
			return;
		}
		dom.content(out, E('em', {}, _('Checking…')));
		return callCheck(domain).then(function(r) {
			var msg;
			if (r.error && !r.result)
				msg = E('span', { 'style': 'color:#c62828' }, r.error);
			else if (r.result === 'blocked')
				msg = E('span', {}, [ E('strong', { 'style': 'color:#c62828' }, _('Blocked')), ' ', _('by the entry for %s').format(r.matched) ]);
			else if (r.result === 'allowed')
				msg = E('span', {}, [ E('strong', { 'style': 'color:#2e7d32' }, _('Allowed')), ' ', _('by the allowlist entry for %s').format(r.matched) ]);
			else
				msg = E('span', {}, [ E('strong', {}, _('Not blocked')), ' ', r.error ? '(' + r.error + ')' : _('(no list entry for it or any parent domain)') ]);
			dom.content(out, msg);
		});
	},

	refresh: function() {
		var self = this;
		return callStatus().then(function(st) {
			self.status = st;
			// do not rebuild the status table while the schedule selector has focus (open or being changed);
			// an unapplied pick is kept by renderSchedule() when the table is rebuilt
			var sel = document.getElementById('abl-schedule');
			if (!(sel && document.activeElement === sel))
				dom.content(document.getElementById('abl-status'), self.renderStatus(st));
			dom.content(document.getElementById('abl-resources'), self.renderResources(st));
			dom.content(document.getElementById('abl-lists'), self.renderLists(st));
			dom.content(document.getElementById('abl-buttons'), self.renderButtons(st));
		});
	},

	render: function(st) {
		if (!st.installed)
			return E('div', { 'class': 'alert-message warning' }, _('adblock-lean-plus is not installed.'));
		if (!st.configured)
			return E('div', { 'class': 'alert-message warning' }, _('adblock-lean-plus has no blockset config (/etc/adblock-lean/blockset-*.conf).'));

		var view = E([], [
			E('h2', {}, _('Adblock-lean-plus')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Status')),
				E('div', { 'id': 'abl-status' }, this.renderStatus(st)),
				E('div', { 'id': 'abl-buttons', 'style': 'margin-top:1em' }, this.renderButtons(st))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Router resources')),
				E('div', { 'id': 'abl-resources' }, this.renderResources(st))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Would this domain be blocked?')),
				E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;align-items:center' }, [
					E('input', {
						'id': 'abl-check-domain', 'type': 'text', 'class': 'cbi-input-text',
						'placeholder': 'ads.example.com', 'maxlength': 254, 'style': 'min-width:18em',
						'keydown': L.bind(function(ev) { if (ev.keyCode === 13) this.handleCheck(ev); }, this)
					}),
					E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleCheck') }, _('Check'))
				]),
				E('p', { 'id': 'abl-check-result', 'style': 'margin-top:.6em' }, '')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Lists')),
				E('div', { 'id': 'abl-lists' }, this.renderLists(st))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Backup')),
				E('p', { 'class': 'cbi-value-description' },
					_('Saves or restores the lists, the local allowlist and blocklist, the update schedule and start at boot.')),
				E('input', { 'type': 'file', 'id': 'abl-import-file', 'accept': '.json,application/json', 'style': 'display:none',
					'change': L.bind(this.handleImportFile, this) }),
				E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap' }, [
					E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleBackup') }, _('Download backup')),
					E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function() { document.getElementById('abl-import-file').click(); } }, _('Import…'))
				])
			])
		]);

		this.status = st;
		var self = this;
		window.setTimeout(function() { self.loadNames(); }, 0);
		poll.add(L.bind(this.refresh, this), 5);
		return view;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
