'use strict';
// SPDX-License-Identifier: GPL-2.0-only
'require view';
'require rpc';
'require poll';
'require dom';

var callLog = rpc.declare({ object: 'luci.adblock-lean', method: 'log', expect: { '': {} } });

function pre(id, text) {
	return E('pre', { 'id': id, 'style': 'white-space:pre-wrap;max-height:30em;overflow:auto;font-size:90%' }, text || _('(empty)'));
}

return view.extend({
	load: function() {
		return callLog();
	},

	render: function(lg) {
		poll.add(function() {
			return callLog().then(function(l) {
				dom.content(document.getElementById('abl-session'), l.session || _('(empty)'));
				dom.content(document.getElementById('abl-syslog'), l.syslog || _('(empty)'));
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
