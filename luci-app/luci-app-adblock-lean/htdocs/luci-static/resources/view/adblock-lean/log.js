'use strict';
// SPDX-License-Identifier: GPL-2.0-only
// Modified in adblock-lean-plus (2026-11): see FORK-NOTES.md for the changes against upstream.
'require view';
'require rpc';
'require poll';
'require dom';

var callLog = rpc.declare({ object: 'luci.adblock-lean', method: 'log', expect: { '': {} } });

// log text may contain list content (e.g. a 'rogue element'): set it as text, never as HTML
function pre(id, text) {
	var el = E('pre', { 'id': id, 'style': 'white-space:pre-wrap;max-height:30em;overflow:auto;font-size:90%' });
	el.textContent = text || _('(empty)');
	return el;
}

return view.extend({
	load: function() {
		return callLog();
	},

	render: function(lg) {
		poll.add(function() {
			return callLog().then(function(l) {
				document.getElementById('abl-session').textContent = l.session || _('(empty)');
				document.getElementById('abl-syslog').textContent = l.syslog || _('(empty)');
			});
		}, 10);
		return E([], [
			E('h2', {}, _('Adblock-lean: log')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Most recent session')),
				pre('abl-session', lg.session)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('System log')),
				pre('abl-syslog', lg.syslog)
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
