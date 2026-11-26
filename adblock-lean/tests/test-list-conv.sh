#!/bin/sh
# Tests for list sanitizing and AdGuard-syntax conversion in abl-process.sh.
# Runs with busybox (OpenWrt) or GNU tools; needs only sh, sed, awk.
# usage: sh tests/test-list-conv.sh [path/to/abl-process.sh]
# Prints one line per failed check and 'PASS n/n' or 'FAIL k/n' at the end; exit code 0 only on PASS.

PROC="${1:-$(dirname "$0")/../usr/lib/adblock-lean/abl-process.sh}"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "${T}"' EXIT

SED_CMD=sed AWK_CMD=awk ABL_TMP_DIR="${T}" index=t
adg_allow_file="${T}/allow" adg_imp_file="${T}/imp" adg_skip_file="${T}/skip"
UTF8_BOM="$(printf '\357\273\277')"

# Load the two helper functions straight from abl-process.sh (they are nested in process_set_part)
for f in sanitize_part conv_adguard_to_raw
do
	${AWK_CMD} -v f="${f}" '
		$0 ~ "^\t" f "\\(\\)$" { on = 1 }
		on { print }
		on && /^\t}$/ { exit }' "${PROC}" > "${T}/${f}.sh"
	[ -s "${T}/${f}.sh" ] || { echo "can not extract ${f} from ${PROC}"; exit 1; }
	. "${T}/${f}.sh"
done

n=0 fails=0
check() {
	n=$((n+1))
	[ "${2}" = "${3}" ] && return 0
	fails=$((fails+1))
	printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "${1}" "$(printf %s "${3}" | tr '\n' ' ')" "$(printf %s "${2}" | tr '\n' ' ')"
}

# --- sanitize_part
out="$(printf '%sbom.example.com\n[Adblock Plus]\n! Title: x\n  ! checksum: abc\n# comment\nok.example.com # trailing\nsite.com##.banner\n##.ad\n\n  spaced.example.com  \n' "${UTF8_BOM}" | sanitize_part)"
check "sanitize: BOM, [Adblock Plus] header, '!' and '#' comments, cosmetic rules, whitespace" "${out}" "bom.example.com
ok.example.com
spaced.example.com"

out="$(printf '  indented.example.com##.banner\nnote.example.com## a note\nhash.example.com#comment\n' | sanitize_part)"
check "sanitize: indented cosmetic rule dropped, '## note' comment kept as domain" "${out}" "note.example.com
hash.example.com"

# --- conv_adguard_to_raw
adg() { rm -f "${adg_allow_file}" "${adg_imp_file}" "${adg_skip_file}"; printf '%s\n' "$@" | sanitize_part | conv_adguard_to_raw; }

check "plain ||d^ and variants" "$(adg '||a.example.com^' '||b.example.com^|' '||c.example.com' '|d.example.com^' 'e.example.com' '0.0.0.0 f.example.com' '||UPPER.Example.COM^')" \
"a.example.com
b.example.com
c.example.com
d.example.com
e.example.com
f.example.com
upper.example.com"

check "subdomain-only rule becomes a plain domain (no dnsmasq wildcards)" "$(adg '.sub.example.com^')" "sub.example.com"

check "blocking dnsrewrite and important" "$(adg '||p.example.com^$dnsrewrite=ad-block.dns.adguard.com' '||q.example.com^$dnsrewrite=NXDOMAIN' '||r.example.com^$dnsrewrite=REFUSED' '||s.example.com^$important')" \
"p.example.com
q.example.com
r.example.com
s.example.com"

out="$(adg '||rw.example.com^$dnsrewrite=1.2.3.4' '||ad-*.example.com^' '/^ads[0-9]+\./' '||client.example.com^$client=192.168.1.2' '||partial.' '||x.example.com^$denyallow=y.com')"
check "unsupported rules are skipped" "${out}" ""
check "unsupported rules are counted" "$(cat "${adg_skip_file}")" "6"

out="$(adg '||blocked.example.com^' '@@||ok.example.com^' '@@||ok2.example.com^|' '@@|exact.example.com^|' '@@/regex/')"
check "exceptions are not blocked" "${out}" "blocked.example.com"
check "exceptions go to the allow file" "$(cat "${adg_allow_file}")" "ok.example.com
ok2.example.com
exact.example.com"

out="$(adg '||pl.ua^' '||keep.example.com^' '||pl.ua^$badfilter' '||other.example.com^$important,badfilter' '||other.example.com^$important')"
check "badfilter disables the identical rule, even if it comes later" "${out}" "keep.example.com"

out="$(adg '||imp.example.com^$important' '@@||imp.example.com^' '@@||imp2.example.com^$important' '||imp2.example.com^$important')"
check "important block beats a plain exception" "${out}" "imp.example.com
imp2.example.com"
check "important exception is kept" "$(cat "${adg_allow_file}")" "imp2.example.com"

check "empty list" "$(adg '! only comments')" ""

check "uppercase BADFILTER is honoured" "$(adg '||pl.ua^' '||keep2.example.com^' '||pl.ua^$BADFILTER')" "keep2.example.com"

out="$(adg '||x.example.com^$important' '||x.example.com^$important,badfilter' '@@||x.example.com^')"
check "a badfiltered important rule does not suppress exceptions" "${out}" ""
check "  ...the exception is kept" "$(cat "${adg_allow_file}")" "x.example.com"

out="$(adg '||ads.example.com^$important' '@@||example.com^')"
check "important subdomain block with a parent exception: block kept" "${out}" "ads.example.com"
check "  ...parent exception kept" "$(cat "${adg_allow_file}")" "example.com"
check "  ...important domain listed for protection" "$(cat "${adg_imp_file}")" "ads.example.com"

check "hosts syntax: only 0.0.0.0/:: blocks, no localhost, no IP targets" \
	"$(adg '127.0.0.1 localhost' '127.0.0.1 tracker.example.com' '0.0.0.0 0.0.0.0' '0.0.0.0 localhost.localdomain' '0.0.0.0 h.example.com' ':: h6.example.com' '||1.2.3.4^')" \
	"h.example.com
h6.example.com"

check "CRLF line endings" "$(printf '||crlf.example.com^\r\n@@||ok-crlf.example.com^\r\n' | sanitize_part | { rm -f "${adg_allow_file}"; conv_adguard_to_raw; })" "crlf.example.com"

if [ "${fails}" = 0 ]
then
	echo "PASS ${n}/${n}"
else
	echo "FAIL ${fails}/${n}"
	exit 1
fi
