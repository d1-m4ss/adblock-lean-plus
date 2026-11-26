'use strict';
// SPDX-License-Identifier: GPL-2.0-only
// Added in adblock-lean-plus (2026-11): the ready-made lists and the names shown for list addresses,
// shared by the Overview and Subscriptions pages.
'require baseclass';

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

function presetName(source) {
	var all = PRESETS.reduce(function(acc, g) { return acc.concat(g[1]); }, []), m;
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

// names of AdGuard's catalog, by download URL; filled once the catalog is loaded
var catalogNames = Object.create(null);

return baseclass.extend({
	PRESETS: PRESETS,
	// a preset's name or null
	preset: presetName,
	// a preset's or catalog list's name, or null
	name: function(source) {
		return presetName(source) || catalogNames[source] || null;
	},
	// take the names from a get_catalog reply
	remember: function(catalog) {
		(catalog.filters || []).forEach(function(f) { catalogNames[f.downloadUrl] = f.name; });
	}
});
