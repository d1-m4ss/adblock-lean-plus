#!/bin/sh
# Tests for the per-list count of entries no other list has: dedup_count_uniq() in abl-process.sh and the parsing
# of its log lines in the LuCI backend (refresh_list_stats in luci.adblock-lean).
# Runs with busybox (OpenWrt) or GNU tools; needs only sh, sed, sort and awk.
# usage: sh tests/test-uniq-count.sh [path/to/abl-process.sh] [path/to/luci.adblock-lean]
# Prints one line per failed check and 'PASS n/n' or 'FAIL k/n' at the end; exit code 0 only on PASS.

D="$(dirname "$0")"
PROC="${1:-${D}/../usr/lib/adblock-lean/abl-process.sh}"
RPCD="${2:-${D}/../../luci-app/luci-app-adblock-lean/root/usr/libexec/rpcd/luci.adblock-lean}"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "${T}"' EXIT

AWK_CMD=awk SORT_CMD=sort SED_CMD=sed proc_dir="${T}"

# Load dedup_count_uniq straight from abl-process.sh (it is nested in gen_blockset)
${AWK_CMD} '$0 ~ "^\tdedup_count_uniq\\(\\)$" { on = 1 } on { print } on && /^\t}$/ { exit }' "${PROC}" > "${T}/f.sh"
[ -s "${T}/f.sh" ] || { echo "can not extract dedup_count_uniq from ${PROC}"; exit 1; }
. "${T}/f.sh"

# and refresh_list_stats from the LuCI backend (a top-level function)
${AWK_CMD} '/^refresh_list_stats\(\) \{$/ { on = 1 } on { print } on && /^}$/ { exit }' "${RPCD}" > "${T}/r.sh"
[ -s "${T}/r.sh" ] || { echo "can not extract refresh_list_stats from ${RPCD}"; exit 1; }
. "${T}/r.sh"

n=0 fails=0
check() {
	n=$((n+1))
	[ "${2}" = "${3}" ] && return 0
	fails=$((fails+1))
	printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "${1}" "$(printf %s "${3}" | tr '\n' ' ')" "$(printf %s "${2}" | tr '\n' ' ')"
}

# what print_set_parts ... tag gives: parts 1, 2 and 10, with a duplicate inside part 1
tagged() {
	printf '%s 1\n' a.com shared.com x.a.com a.com
	printf '%s 2\n' shared.com b.com a.com-cdn.net
	printf '%s 10\n' shared.com only10.org a.com
}

rm -f "${T}/uniq_stats"
check "every domain once, sorted" "$(tagged | dedup_count_uniq)" \
"a.com
a.com-cdn.net
b.com
only10.org
shared.com
x.a.com"

check "per-list counts: duplicates inside one list count once, a domain in two lists is unique to none" \
	"$(sort "${T}/uniq_stats")" \
"1 1
10 1
2 2"

rm -f "${T}/uniq_stats"
printf '%s 3\n' c.com c.com | dedup_count_uniq > /dev/null
check "a list's own duplicates still unique" "$(cat "${T}/uniq_stats")" "3 1"

rm -f "${T}/uniq_stats"
check "empty input: no output, no stats" "$(printf '' | dedup_count_uniq)$(cat "${T}/uniq_stats" 2>/dev/null)" ""

rm -f "${T}/uniq_stats"
printf '%s 4\n' z.com > "${T}/in"; printf '%s 5\n' z.com >> "${T}/in"
dedup_count_uniq < "${T}/in" > /dev/null
check "no unique entries: no stats line" "$(cat "${T}/uniq_stats" 2>/dev/null)" ""

rm -f "${T}/uniq_stats"
check "number-like entries are compared as text: none lost" \
	"$(printf '%s\n' '0 1' '00 1' '000 2' '1.1 1' '1.10 2' '1e2 1' '100 2' | dedup_count_uniq)" \
"0
00
000
1.1
1.10
100
1e2"
check "number-like entries: counts" "$(sort "${T}/uniq_stats")" \
"1 4
2 3"

# --- the backend reads the figures from the session log
ESC="$(printf '\033')" CACHE_DIR="${T}/cache" ABL_SESSION_LOG="${T}/log"
{
	printf 'Successfully processed part:    %shagezi:pro.plus%s   [ %s4.73 MiB%s  -   %s255,860 entries%s ]\n' "${ESC}[0;32m" "${ESC}[0m" "${ESC}[0;33m" "${ESC}[0m" "${ESC}[0;33m" "${ESC}[0m"
	printf 'Successfully processed part:    https://example.com/list.txt   [ 12 KiB  -   1,042 entries ]\n'
	printf 'Successfully processed part:    /etc/adblock-lean/local-allowlist-01   [ 0 B  -   0 entries ]\n'
	printf 'Entries no other list has:    %shagezi:pro.plus%s   [ %s102,537%s ]\n' "${ESC}[0;32m" "${ESC}[0m" "${ESC}[0;33m" "${ESC}[0m"
	printf 'Entries no other list has:    https://example.com/list.txt   [ 0 ]\n'
	printf 'Successfully installed blockset files\n'
} > "${ABL_SESSION_LOG}"
refresh_list_stats
check "backend: entries and unique counts per list, none for an allowlist" "$(cat "${CACHE_DIR}/lists")" \
"hagezi:pro.plus|4.73 MiB|255860|102537
https://example.com/list.txt|12 KiB|1042|0
/etc/adblock-lean/local-allowlist-01|0 B|0|"

rm -rf "${CACHE_DIR}"
grep -v 'Entries no other list has' "${T}/log" > "${T}/log2" && mv "${T}/log2" "${ABL_SESSION_LOG}"
refresh_list_stats
check "backend: a log without unique counts (deduplication off, older engine)" "$(cat "${CACHE_DIR}/lists")" \
"hagezi:pro.plus|4.73 MiB|255860|
https://example.com/list.txt|12 KiB|1042|
/etc/adblock-lean/local-allowlist-01|0 B|0|"

if [ "${fails}" = 0 ]
then
	echo "PASS ${n}/${n}"
else
	echo "FAIL ${fails}/${n}"
	exit 1
fi
