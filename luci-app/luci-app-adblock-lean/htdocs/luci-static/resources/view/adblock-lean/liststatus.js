'use strict';
// SPDX-License-Identifier: GPL-2.0-only
// Added in adblock-lean-plus (2026-11): how the result of a list's last download is shown, shared by the
// Overview and Subscriptions pages.
'require baseclass';

// colour and sign of each state
var LOOK = {
	ok: [ '#2e7d32', '✓' ],
	fail: [ '#c62828', '!' ],
	off: [ '#8a8a8a', '–' ],
	unknown: [ '#8a8a8a', '?' ]
};

// a list address as a key: short ids are case-insensitive
function key(source) {
	return /^https?:/i.test(source) ? source : String(source).toLowerCase();
}

// the router's reason code in words
function reason(code) {
	var http = /^http_([0-9]+)$/.exec(code);
	if (http)
		return _('HTTP error %d').format(+http[1]);
	switch (code) {
		case 'net': return _('server not reachable');
		case 'content': return _('not a block list');
		case 'few': return _('too few usable entries');
		case 'size': return _('larger than the size limit');
		case 'timeout': return _('timed out');
	}
	return _('processing failed');
}

function when(ts) {
	return new Date(ts * 1000).toLocaleString(undefined, { dateStyle: 'short', timeStyle: 'short' });
}

// a round sign, a text and optional further lines (a text or an array of texts); the texts become text nodes. oneLine keeps a short text
// (a figure) next to its sign, longer texts may wrap on narrow screens.
function badge(kind, text, detail, oneLine) {
	var look = LOOK[kind];
	return E('div', {}, [
		E('div', { 'style': oneLine ? 'white-space:nowrap' : null }, [
			E('span', { 'aria-hidden': 'true', 'style': 'display:inline-block;width:1.35em;height:1.35em;line-height:1.35em;' +
				'border-radius:50%;margin-right:.45em;text-align:center;font-size:85%;font-weight:bold;color:#fff;background:' + look[0] }, look[1]),
			E('span', {}, [ text ])
		]),
		E('div', { 'style': 'font-size:90%;opacity:.75' }, [].concat(detail || []).map(function(line) {
			return E('div', {}, [ line ]);
		}))
	]);
}

return baseclass.extend({
	key: key,
	reason: reason,
	badge: badge,

	// the router's list_status array as a map by list address
	map: function(list) {
		var map = Object.create(null);
		(list || []).forEach(function(s) { map[key(s.name)] = s; });
		return map;
	},

	// the status of one subscription: entry is its record in the map, if any
	cell: function(enabled, entry) {
		if (!enabled)
			return badge('off', _('Switched off'));
		if (!entry)
			return badge('unknown', _('Not updated yet'));
		if (entry.ok)
			return badge('ok', _('Updated'), when(entry.at));
		return badge('fail', _('Failed: %s').format(reason(entry.reason)), [
			_('tried: %s').format(when(entry.at)),
			entry.ok_at ? _('last good: %s').format(when(entry.ok_at)) : _('never loaded')
		]);
	}
});
