'use strict';
// SPDX-License-Identifier: GPL-2.0-only
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

var callStatus = rpc.declare({ object: 'luci.adblock-lean', method: 'status', expect: { '': {} } });
var callAction = rpc.declare({ object: 'luci.adblock-lean', method: 'action', params: [ 'name' ], expect: { '': {} } });
var callCheck = rpc.declare({ object: 'luci.adblock-lean', method: 'check', params: [ 'domain' ], expect: { '': {} } });

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
			row(_('Status'), [ stateBadge(st), busy ? E('em', { 'style': 'margin-left:.6em' }, st.state.substr(5)) : '' ]),
			row(_('Domains blocked'), st.state === 'active' ? E('strong', {}, fmtInt(st.entries)) : '-'),
			row(_('Lists last updated'), fmtAge(st.updated, st.now)),
			row(_('Last update took'), st.last_duration || '-'),
			row(_('Automatic update'), st.cron ? E('code', {}, st.cron) : _('none (no cron job)')),
			row(_('Start at boot'), st.enabled ? _('Yes') : _('No')),
			row(_('dnsmasq'), st.dnsmasq_running ? _('running') : E('strong', { 'style': 'color:#c62828' }, _('not running'))),
			row(_('adblock-lean version'), st.version || '?')
		];
		return E('table', { 'class': 'table' }, rows);
	},

	renderLists: function(st) {
		if (!st.lists || !st.lists.length)
			return E('p', { 'class': 'cbi-value-description' }, _('No per-list figures yet. They appear after the next list update.'));

		var rows = [ E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('List')),
			E('th', { 'class': 'th right' }, _('Entries')),
			E('th', { 'class': 'th right' }, _('Download size'))
		]) ];
		st.lists.forEach(function(l) {
			var local = l.name.indexOf('/') === 0;
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, local ? E('em', {}, l.name.replace('/etc/adblock-lean/', _('local '))) : l.name),
				E('td', { 'class': 'td right' }, fmtInt(l.lines)),
				E('td', { 'class': 'td right' }, l.size.replace(/\s+/g, ' '))
			]));
		});
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, E('strong', {}, _('After merging duplicates'))),
			E('td', { 'class': 'td right' }, E('strong', {}, fmtInt(st.entries))),
			E('td', { 'class': 'td' }, '')
		]));
		return E([], [
			E('table', { 'class': 'table' }, rows),
			E('p', { 'class': 'cbi-value-description' },
				_('From the list update at %s. Lists overlap, so the total is less than the sum.').format(new Date(st.lists_at * 1000).toLocaleString()))
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
		if (st.state === 'active')
			b.push(btn(_('Pause'), 'pause', 'cbi-button-neutral', _('Stop blocking, keep the lists in memory')));
		if (st.state === 'paused')
			b.push(btn(_('Resume'), 'resume', 'cbi-button-positive'));
		if (st.state !== 'stopped')
			b.push(btn(_('Stop'), 'stop', 'cbi-button-negative', _('Stop blocking and unload the lists')));
		b.push(st.enabled ? btn(_('Disable at boot'), 'disable', 'cbi-button-neutral')
			: btn(_('Enable at boot'), 'enable', 'cbi-button-positive'));
		return E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap' }, b);
	},

	handleAction: function(action) {
		var self = this;
		if (action === 'stop' && !confirm(_('Stop adblock-lean? Ads will not be blocked until it is started again.')))
			return;
		return callAction(action).then(function(r) {
			if (!r.ok)
				ui.addNotification(null, E('p', r.error || _('Action failed')), 'error');
			return self.refresh();
		});
	},

	handleCheck: function(ev) {
		var input = document.getElementById('abl-check-domain'),
		    out = document.getElementById('abl-check-result');
		var domain = (input.value || '').trim();
		if (!domain)
			return;
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
			dom.content(document.getElementById('abl-status'), self.renderStatus(st));
			dom.content(document.getElementById('abl-lists'), self.renderLists(st));
			dom.content(document.getElementById('abl-buttons'), self.renderButtons(st));
		});
	},

	render: function(st) {
		if (!st.installed)
			return E('div', { 'class': 'alert-message warning' }, _('adblock-lean is not installed.'));

		var view = E([], [
			E('h2', {}, _('Adblock-lean')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Status')),
				E('div', { 'id': 'abl-status' }, this.renderStatus(st)),
				E('div', { 'id': 'abl-buttons', 'style': 'margin-top:1em' }, this.renderButtons(st))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Would this domain be blocked?')),
				E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;align-items:center' }, [
					E('input', {
						'id': 'abl-check-domain', 'type': 'text', 'class': 'cbi-input-text',
						'placeholder': 'ads.example.com', 'style': 'min-width:18em',
						'keydown': L.bind(function(ev) { if (ev.keyCode === 13) this.handleCheck(ev); }, this)
					}),
					E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleCheck') }, _('Check'))
				]),
				E('p', { 'id': 'abl-check-result', 'style': 'margin-top:.6em' }, '')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Lists')),
				E('div', { 'id': 'abl-lists' }, this.renderLists(st))
			])
		]);

		poll.add(L.bind(this.refresh, this), 5);
		return view;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
