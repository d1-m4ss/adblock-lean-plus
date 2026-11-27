#!/bin/sh
# Tests the retries of a list download in abl-process.sh: an attempt must not inherit the verdict of an
# earlier one. Runs on OpenWrt (a router or the rootfs container), works only in its own temporary directory.
# usage: sh tests/test-list-retry.sh
# Prints one line per failed check and 'PASS n/n' or 'FAIL k/n' at the end; exit code 0 only on PASS.

B="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "${T}"' EXIT

luci_skip_dialogs=1 MSGS_DEST=/dev/null
export luci_skip_dialogs MSGS_DEST
. "${B}/adblock-lean" || exit 1
ABL_CFG_DIR="${T}/cfg" ABL_RUN_DIR="${T}/run" ABL_TMP_DIR="${T}/tmp" ABL_CURR_LOG_FILE="${T}/log"
for f in abl-lib.sh abl-process.sh
do
	. "${B}/usr/lib/adblock-lean/${f}" || exit 1
done
[ "${PROCESSED_PARTS_DIR}" = "${T}/tmp/blockset_parts" ] || { echo "unsafe paths: ${PROCESSED_PARTS_DIR}"; exit 1; }
mkdir -p "${ABL_CFG_DIR}" "${PROCESSED_PARTS_DIR}" || exit 1

LOG_CMD=true AWK_CMD=awk SED_CMD=sed CAT_CMD=cat INTERM_COMPR_OR_CAT_STDOUT=cat UCL_CMD=fake_fetch SCHEDULER_PID=$$
sleep() { [ "${1}" = 5 ] || command sleep "${1}"; } # no waiting between attempts

# answers with ${ANSWERS}, one per attempt: 'page' (a web page), 'list' (a good list), 'few' (an empty list)
fake_fetch() {
	local a
	read -r a < "${T}/answers"
	sed -i 1d "${T}/answers"
	case "${a}" in
		page) printf '<html><body>sorry</body></html>\n' ;;
		list) printf 'a.example.com\nb.example.com\n' ;;
		few) : ;;
	esac
	echo "Download completed" >&2
}

# 1: answers; sets rv, reason (of the last failed attempt) and got (the processed part)
attempts() {
	rm -rf "${PROCESSED_PARTS_DIR}"; mkdir -p "${PROCESSED_PARTS_DIR}"
	printf '%s\n' ${1} > "${T}/answers"
	(
		set -f -o pipefail
		format=raw origin=DL print_id=https://lists.invalid/list.txt dest_file="${PROCESSED_PARTS_DIR}/part_1" \
		part_stats_file="${PROCESSED_PARTS_DIR}/1_stats" is_ipv4=0 max_download_attempts=2 max_part_size=100 \
		min_part_entries=1
		process_set_part 1 >/dev/null 2>&1
	)
	rv=$?
	reason=; [ -f "${PROCESSED_PARTS_DIR}/1_fail" ] && read -r reason < "${PROCESSED_PARTS_DIR}/1_fail"
	got="$(cat "${PROCESSED_PARTS_DIR}/part_1" 2>/dev/null | tr '\n' ' ')"
}

n=0 fails=0
check() {
	n=$((n+1))
	[ "${2}" = "${3}" ] && return 0
	fails=$((fails+1))
	printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "${1}" "${3}" "${2}"
}
GOOD="a.example.com b.example.com "

attempts "list"
check "good at once" "${rv} ${got}" "0 ${GOOD}"
attempts "few list"
check "empty answer, then a good one" "${rv} ${got}" "0 ${GOOD}"
attempts "page list"
check "web page, then a good list" "${rv} ${got}" "0 ${GOOD}"
attempts "page page"
check "web page twice: fails as 'not a block list'" "${rv} ${reason}" "2 content"
attempts "page few"
check "web page, then empty: the reason is the last one" "${rv} ${reason}" "2 few"

# the rogue elements check runs beside the pipeline: its verdict counts even when it is the last to finish
# (an external command, as the real sed is: a shell function would itself hold the pipeline open)
printf '#!/bin/sh\ncase "$*" in *";b1") sleep 1; esac\nexec sed "$@"\n' > "${T}/slow_sed"
chmod +x "${T}/slow_sed"
SED_CMD="${T}/slow_sed"
attempts "page page"
check "slow check, web page twice" "${rv} ${reason}" "2 content"
attempts "page list"
check "slow check, web page, then a good list" "${rv} ${got}" "0 ${GOOD}"
SED_CMD=sed

if [ "${fails}" = 0 ]
then echo "PASS ${n}/${n}"
else echo "FAIL ${fails}/${n}"; exit 1
fi
