#!/bin/sh
# Modified in adblock-lean-plus (2026-11): see FORK-NOTES.md for the changes against upstream.
# shellcheck disable=SC3043,SC3001,SC2016,SC2015,SC3020,SC2181,SC2019,SC2018,SC3045,SC3003,SC3060,SC3057,SC3040

# silence shellcheck warnings
: "${blockset_part_failed_action:=}" \
	"${max_download_attempts:=}" "${deduplication:=}" \
	"${blue:=}" "${lblue:=}" "${green:=}" "${red:=}" "${yellow:=}" "${orange:=}" "${n_c:=}"

PROCESSED_PARTS_DIR="${ABL_TMP_DIR}/blockset_parts"

ERR_F="${ABL_TMP_DIR}/process-errors"

# result of the last download of every list, read by the web interface; on flash because the logs are in RAM
LIST_STATUS_F="${ABL_CFG_DIR}/list-status"

ABL_TEST_DOM_BASE="adblocklean-test.totallybogus"

ALL_PART_FORMATS="raw hosts adguard"

# UTF-8 byte order mark, stripped from the first line of every part
UTF8_BOM="$(printf '\357\273\277')"
ALL_PART_TYPES="allow block ipv4_block"


# shellcheck disable=SC2034
hagezi_lists="anti.piracy blocklist-referral doh doh-vpn-proxy-bypass dyndns fake gambling gambling.medium gambling.mini hoster \
light multi native.amazon native.apple native.huawei native.lgwebos native.oppo-realme native.roku native.samsung \
native.tiktok native.tiktok.extended native.vivo native.winoffice native.xiaomi nosafesearch nsfw popupads \
pro pro.mini pro.plus pro.plus.mini social tif tif.medium tif.mini ultimate ultimate.mini urlshortener whitelist-referral" \
hagezi_formats="raw" \
hagezi_mirrors="github gitlab" \
	hagezi_github_url="https://raw.githubusercontent.com/hagezi/dns-blocklists/main" \
	hagezi_gitlab_url="https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists" \
\
oisd_lists="big small nsfw nsfw-small" \
oisd_formats="raw" \
oisd_mirrors="oisd github" \
	oisd_oisd_url="oisd.nl" \
	oisd_github_url="https://raw.githubusercontent.com/sjhgvr/oisd/main" \
\
stevenblack_lists="base fakenews gambling porn social" \
stevenblack_formats="hosts" \
stevenblack_mirrors="github sbc_io" \
	stevenblack_github_url="https://raw.githubusercontent.com/StevenBlack/hosts/master" \
	stevenblack_sbc_io_url="http://sbc.io/hosts"


# UTILITY FUNCTIONS

# To use, first get initial uptime: 'get_uptime_cs INITIAL_UPTIME'
# Then call this function to get elapsed time string at desired intervals, e.g.:
# get_elapsed_time_cs elapsed_time_cs "${INITIAL_UPTIME}"
# 1 - var name for centiseconds output
# 2 - initial uptime in centiseconds
get_elapsed_time_cs() {
	local ge_uptime_cs
	clear_vars "${1}"
	get_uptime_cs ge_uptime_cs &&
	export -n "${1}=$(( ge_uptime_cs - ${2:-ge_uptime_cs} ))"
}

# 1: var name for output
# 2: reference time in centiseconds
get_elapsed_time_human() {
	local _e_m _e_s _e_cs _e_elapsed _elapsed_human
	clear_vars "${1}"
	get_elapsed_time_cs _e_elapsed "${2}" || return 1
	_e_m=$(( _e_elapsed / 6000 ))
	[ "$_e_m" -gt 0 ] || _e_m=
	_e_cs=$(( _e_elapsed % 6000 ))
	_e_s=$(( _e_cs / 100 ))
	case "${_e_cs}" in
		'') _e_cs=00 ;;
		?) _e_cs="0${_e_cs}" ;;
		??) ;;
		??*) _e_cs="${_e_cs#"${_e_cs%??}"}"
	esac
	is_uint "${_e_m:-0}" "${_e_s}" "${_e_cs}" &&
		_elapsed_human="${_e_m:+"${_e_m}m:"}${_e_s}.${_e_cs}s"
	export -n "${1}=${_elapsed_human}"
}


# HELPER FUNCTIONS

# Env vars: TESTED_URLS
test_fetch_doms()
{
	local list lists list_cat feed_author url mirror all_urls type format \
		doms valid_doms dom recs \
		set_id="${1:?}"

	for type in block ipv4_block allow
	do
		for format in ${ALL_PART_FORMATS:?}
		do
			local list_cat="${format}_${type}_lists"
			dbg_off
			get_bl_param_gl_var _ "${list_cat}" || { dbg_on; continue; } # ignore invalid combinations
			dbg_on
			local "${list_cat}="
			get_params "${set_id}" lists="${list_cat}"

			[ -z "${lists}" ] && continue
			for list in ${lists}
			do
				case "${list}" in
					'') continue ;;
					hagezi:*|oisd:*|stevenblack:*)
						feed_author="${list%%":"*}"
						eval "mirror=\"\${${feed_author}_default_mirror}\""
						eval "url=\"\${${feed_author}_${mirror}_url}\""
						[ -n "${url}" ] ;;
					*) url="${list}"
				esac &&
				is_included "${url}" "${TESTED_URLS}" "${_NL_}" && continue
				abl_append all_urls "${url}" "${_NL_}"
			done
		done
	done

	[ -n "${all_urls}" ] || return 0

	reg_action "Testing connectivity."
	debug_msg "URLs:${_NL_}${all_urls}"

	doms="$(
		printf '%s\n' "${all_urls}" |
		${SED_CMD:?} -n '/http/{s~^http[s]*[:]*[/]*~~g;s~/.*~~;/^$/d;p;}' |
		${SORT_CMD:?} -u)
	"

	[ -n "${doms}" ] || return 0

	# Get list of valid domain names, ignore invalid
	validate_doms valid_doms "${doms}" || return 1

	# Every domain is tested against the same nameservers, so one pseudo-instance ID suffices
	for dom in ${valid_doms}
	do
		abl_append recs "con__${dom} ${dom} ${PRIMARY_NS:?}" "${_NL_}"
	done

	# All url-domains must resolve
	LOOKUP_FAIL_EARLY=1 lookup_targets _ "${recs}" 7 || return 1

	abl_append TESTED_URLS "${all_urls}" "${_NL_}"
	:
}

# 1 - var name for output
# 2 - list URL or short identifier
# 3 - list format (raw|hosts)
# 4 - DL mirror
# shellcheck disable=SC2329
get_feed_url()
{
	local base_url prefix suffix raw_suffix hosts_suffix \
		gfu_res feed_author list_name lists list_id_lc formats \
		mirrors first_mirror \
		gfu_out_var="${1}" list_id="${2}" format="${3}" mirror="${4}"

	clear_vars "${gfu_out_var}"

	case "${format}" in raw|hosts|adguard) ;; *) reg_fail "Unexpected list format '${format}'."; return 1; esac

	tolower list_id_lc "${list_id}"
	case "${list_id_lc}" in hagezi:*|oisd:*|stevenblack:*) ;; *)
		export -n "${gfu_out_var}=${list_id}"
		return 0
	esac
	list_id="${list_id_lc}"

	feed_author="${list_id%%\:*}" list_name="${list_id#*\:}"

	eval "lists=\"\${${feed_author}_lists}\""
	eval "base_url=\"\${${feed_author}_${mirror}_url}\""
	[ -n "${base_url}" ] || { reg_fail "Failed to get base URL for ${feed_author} mirror '${mirror}'."; return 1; }

	is_included "${list_name}" "${lists}" || { reg_fail "Unknown ${feed_author} list '${2}'."; return 1; }

	eval "formats=\"\${${feed_author}_formats}\""
	is_included "${format}" "${formats}" ||
		{ reg_fail "${list_id} is only available in formats: ${formats}."; return 1; }

	eval "mirrors=\"\${${feed_author}_mirrors}\""
	is_included "${mirror}" "${mirrors}" ||
		{ reg_fail "Unexpected mirror '${mirror}' for list author ${feed_author}."; return 1; }

	case "${feed_author}" in
		hagezi)
			prefix="${base_url}"
			raw_suffix="/wildcard/${list_name}-onlydomains.txt" ;;
		stevenblack)
			prefix="${base_url}"
			case "${list_name}" in
				base) hosts_suffix="/hosts" ;;
				*) hosts_suffix="/alternates/${list_name}-only/hosts"
			esac ;;
		oisd)
			case "${mirror}" in
				oisd)
					prefix="https://${list_name}.${base_url}"
					raw_suffix="/domainswild2" ;;
				github)
					prefix="${base_url}"
					list_name="${list_name//-/_}"
					raw_suffix="/domainswild2_${list_name}.txt" ;;
			esac
	esac

	eval "suffix=\"\${${format}_suffix}\""
	gfu_res="${prefix}${suffix}"
	[ -n "${gfu_res}" ] || { reg_fail "Failed to construct URL for list identifier '${list_id}'."; return 1; }

	: "${raw_suffix}" "${hosts_suffix}"
	export -n "${gfu_out_var}=${gfu_res}"
}

get_part_process_path()
{
	export -n "${1:?}=${PROCESSED_PARTS_DIR:?}/part_${2:?}${INTERM_COMPR_EXT}"
}

# 1: list index
# 2: list type (block|ipv4_block|allow)
# 3: list format (raw|hosts)
# 4: blockset ID
# 5: scheduler PID
# the rest of the args passed as-is to workers
#
# return codes:
# 0: Success
# 1: Fatal error (stop processing)
# 2: Download failure
# 3: Processing failure
# 4: Size exceeded
# shellcheck disable=SC2317,SC2329
process_set_part()
{
	dl_feed() { ${UCL_CMD:?} "${1}" -O- --timeout=3 2> "${ucl_err_file}"; }

	# 1: why the part failed (http_<code>|net|content|few|size|error), for save_list_status()
	set_fail_reason() { printf '%s\n' "${1}" > "${PROCESSED_PARTS_DIR}/${index}_fail"; }

	conv_hosts_to_raw()
	{
		${SED_CMD} -nE '
			/^\s*(0[.]0[.]0[.]0|::)\s+(0[.]0[.]0[.]0|::)\s*$/d;
			s/^\s*(0[.]0[.]0[.]0|::)\s+([^. 	]+([.][^. 	]+)+)$/\2/p
		' |
		# subdomains compression - slightly improved variant of code from adblock by Dirk Brenken
		${AWK_CMD} -F "." '{for(f=NF;f>1;f--)printf "%s.",$f;print $1}' | # invert labels order
		${SORT_CMD} |
		${SED_CMD} '/^$/d' |
		${AWK_CMD} '{if(NR==1){DOM=$0}; while(getline){if(index($0,DOM".")==0){print DOM;DOM=$0}}; print DOM}' | # compress subdomains
		${AWK_CMD} -F "." '{for(f=NF;f>1;f--)printf "%s.",$f;print $1}' # invert labels order back
	}

	# Converts AdGuard DNS filtering syntax (AdGuard DNS filter, AdGuard Popup Hosts, Hagezi 'adblock' lists etc)
	# to raw domains. Block rules go to STDOUT, exception (@@) rules go to file ${adg_allow_file}.
	# Supported rules (anything else is counted in ${adg_skip_file} and skipped):
	#   ||example.com^  ||example.com^|  ||example.com  |example.com^  example.com  0.0.0.0 example.com
	#   .example.com^ (subdomains only in AdGuard) -> 'example.com', i.e. the domain itself is blocked too:
	#     dnsmasq wildcard entries ('*.example.com') in a large blockset add ~130 ms to every uncached
	#     forwarded query (measured with dnsmasq 2.93), so they are not used
	#   modifiers: $important; for block rules also $dnsrewrite=<blocking answer>
	#     (NXDOMAIN, REFUSED, 0.0.0.0, ::, ad-block.dns.adguard.com)
	#   @@<any of the above>: exception
	#   <rule>$badfilter: disables the identical rule in this list
	# $important block rules win over exceptions for the same domain, as in AdGuard Home.
	# Rules with wildcards, regexes or other modifiers can not be expressed in dnsmasq and are skipped.
	# The input is buffered in a temp file because $badfilter rules may follow the rules they disable.
	conv_adguard_to_raw()
	{
		local adg_tmp="${ABL_TMP_DIR}/adg_input_${index}" adg_rv
		cat > "${adg_tmp}" || { rm -f "${adg_tmp}"; return 1; }
		# the first pass is only needed when the list has badfilter or important rules
		local adg_passes=1 adg_files="${adg_tmp}"
		grep -qiE '[$,](badfilter|important)' "${adg_tmp}" && adg_passes=2 adg_files="${adg_tmp} ${adg_tmp}"
		# shellcheck disable=SC2086
		${AWK_CMD:?} -v passes="${adg_passes}" -v allow_f="${adg_allow_file:?}" -v imp_f="${adg_imp_file:?}" \
			-v skip_f="${adg_skip_file:?}" '
			# returns the rule without "@@", modifiers and anchors in R_DOM, with flags in R_ALLOW, R_IMP;
			# returns 0 if the rule is not supported
			function parse(rule,    p, mods, n, m, i, v) {
				R_ALLOW = 0; R_IMP = 0; R_DOM = ""
				if (substr(rule, 1, 2) == "@@") { R_ALLOW = 1; rule = substr(rule, 3) }
				p = index(rule, "$")
				mods = ""
				if (p) { mods = substr(rule, p + 1); rule = substr(rule, 1, p - 1) }
				if (mods != "") {
					n = split(mods, m, ",")
					for (i = 1; i <= n; i++) {
						if (m[i] == "important") { R_IMP = 1; continue }
						if (!R_ALLOW && substr(m[i], 1, 11) == "dnsrewrite=") {
							v = substr(m[i], 12)
							sub(/\.$/, "", v)
							if (v ~ /^(nxdomain|refused|0\.0\.0\.0|::|ad-block\.dns\.adguard\.com|noerror;cname;ad-block\.dns\.adguard\.com)$/) continue
						}
						return 0
					}
				}
				if (substr(rule, 1, 2) == "||") rule = substr(rule, 3)
				else if (substr(rule, 1, 1) == "|") rule = substr(rule, 2)
				else if (substr(rule, 1, 1) == ".") rule = substr(rule, 2)
				# hosts syntax: only the blocking forms, as in conv_hosts_to_raw
				else if (rule ~ /^(0\.0\.0\.0|::)[ \t]+/) sub(/^[^ \t]+[ \t]+/, "", rule)
				if (substr(rule, length(rule)) == "|") rule = substr(rule, 1, length(rule) - 1)
				if (substr(rule, length(rule)) == "^") rule = substr(rule, 1, length(rule) - 1)
				if (rule !~ /^[a-z0-9_-]+([.][a-z0-9_-]+)+$/) return 0
				# IP address rules and localhost names are not domain blocks
				if (rule ~ /^[0-9.]+$/ || rule ~ /^localhost([.]|$)/) return 0
				R_DOM = rule
				return 1
			}
			FNR == 1 { pass++ }
			{ line = tolower($0); sub(/\r$/, "", line) }
			# pass 1 (only with passes=2): collect $badfilter targets and $important block rules
			passes == 2 && pass == 1 {
				if (line ~ /[$,]badfilter(,|$)/) {
					t = line
					sub(/\$badfilter$/, "", t); sub(/,badfilter,/, ",", t); sub(/,badfilter$/, "", t); sub(/\$badfilter,/, "$", t)
					bad[t]
				}
				else if (parse(line) && !R_ALLOW && R_IMP) imp_rule[line] = R_DOM
				next
			}
			# start of pass 2: $important block rules not disabled by $badfilter win over plain exceptions;
			# they are also written to imp_f so that exceptions for a parent domain do not remove them
			passes == 2 && pass == 2 && FNR == 1 {
				for (r in imp_rule) if (!(r in bad)) { important[imp_rule[r]]; print imp_rule[r] > imp_f }
			}
			# pass 2: convert
			# fast path for the most common rule form, "||example.com^"
			line ~ /^\|\|[a-z0-9_-]+([.][a-z0-9_-]+)+\^$/ {
				if (line ~ /^\|\|[0-9.]+\^$/) skipped++ # IP address rule
				else if (!(line in bad)) print substr(line, 3, length(line) - 3)
				next
			}
			{
				if (line ~ /[$,]badfilter(,|$)/ || (line in bad)) next
				if (!parse(line)) { skipped++; next }
				if (R_ALLOW) {
					if (!R_IMP && (R_DOM in important)) next
					print R_DOM > allow_f
				}
				else print R_DOM
			}
			END { print skipped + 0 > skip_f }
		' ${adg_files}
		adg_rv=${?}
		rm -f "${adg_tmp}"
		return "${adg_rv}"
	}

	# Remove UTF-8 BOM, '!' comment lines and '[Adblock Plus 2.0]'-style headers, cosmetic rules ('example.com##.ad'),
	# comment lines and trailing comments, remove whitespaces
	# (the '#' checks only run on lines that contain '#': this keeps the cost close to a single substitution)
	sanitize_part()
	{
		${SED_CMD:?} "1s/^${UTF8_BOM}//"';
			s/^[ \t]*//;
			/^[![]/d;
			/#/{ /^[^ \t#]*#[@$?%]*#[^ \t]/d; s/#.*$//; };
			s/[ \t]*$//; /^$/d'
	}

	case_conv() { tr 'A-Z' 'a-z'; }

	local index="${1:?}"

	local \
		me=process_set_part \
		\
		feed_author \
		feed_path \
		\
		part_cnt \
		cnt_human \
		part_size_B \
		part_size_human \
		stats_pad \
		suffix_pad \
		\
		min_part_entries_human \
		fetch_cmd \
		\
		pipeline_rv \
		pipeline_msg \
		ucl_err \
		fail_reason \
		rogue_element \
		\
		mirrors \
		mirror \
		cur_mirror \
		first_mirror \
		loop_prev_mirror \
		msg_mirr \
		\
		msg \
		pad \
		print_id_pad \
		mirror_pad \
		\
		ucl_err_file="${ABL_TMP_DIR}/ucl_err_${index}" \
		rogue_el_file="${ABL_TMP_DIR}/rogue_el_${index}" \
		adg_allow_file="${PROCESSED_PARTS_DIR}/${index}_adg_allow" \
		adg_imp_file="${PROCESSED_PARTS_DIR}/${index}_adg_important" \
		adg_skip_file="${ABL_TMP_DIR}/adg_skip_${index}" \
		oversize_file="${ABL_TMP_DIR}/oversize_${index}" \
		adg_skipped \
		part_compr_or_cat="${INTERM_COMPR_OR_CAT_STDOUT:?}"

	# vars set by the scheduler
	assert_set "F_${me}" \
		format \
		origin \
		print_id \
		dest_file \
		part_stats_file \
		is_ipv4 \
		max_download_attempts \
		max_part_size \
		min_part_entries || return 1

	debug_msg "${me}: scheduler_pid: ${SCHEDULER_PID}; index: ${index}; format: ${format}; origin: ${origin}; print_id: ${print_id}; dest_file: ${dest_file}; stats_file: ${part_stats_file}; is_ipv4: ${is_ipv4}; max_part_size: ${max_part_size}"

	if [ "${origin}" = DL ] &&
		feed_author="${print_id%:*}" &&
		case "${feed_author}" in
			hagezi|oisd|stevenblack) : ;;
			*) false
		esac
	then
		eval "mirrors=\"\${${feed_author}_mirrors}\"" &&
		trim_spaces mirrors &&
		[ -n "${mirrors}" ] &&
		first_mirror="${mirrors%% *}" &&
		[ -n "${first_mirror}" ] || { reg_fail "Failed to process download mirrors for list author ${feed_author}."; return 1; }

		eval "cur_mirror=\"\${${feed_author}_default_mirror}\""
		: "${cur_mirror:="${first_mirror}"}"
	fi

	case "${origin}" in
		DL) fetch_cmd=dl_feed ;;
		LOCAL) fetch_cmd="${CAT_CMD:?}" ;;
		*) reg_fail "Invalid list origin '${origin}'."; return 1
	esac

	local \
		format_conv_or_cat="${CAT_CMD:?}" \
		case_conv_or_cat="case_conv" \
		val_entry_regex='^[[:alnum:]-]+$|^(\*|[[:alnum:]_-]+)([.][[:alnum:]_-]+)+$'

	case "${format}" in
		hosts) format_conv_or_cat="conv_hosts_to_raw" ;;
		adguard) format_conv_or_cat="conv_adguard_to_raw"
	esac

	if [ "${is_ipv4}" = 1 ]
	then
		case_conv_or_cat="${CAT_CMD:?}"
		val_entry_regex='^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])$'
	fi

	local prev_mirror next_mirror attempt=1
	while :
	do
		feed_path="${print_id}"
		if [ "${origin}" = DL ] && [ -n "${feed_author}" ]
		then
			prev_mirror="${cur_mirror}"
			read_str_from_file -v cur_mirror -f "${PROCESSED_PARTS_DIR}/${feed_author}-forced-mirror" -a 1 -q -n 128 ||
				cur_mirror="${prev_mirror}"
			# Get URL, taking into account forced mirror for this feed author if set
			get_feed_url feed_path "${print_id}" "${format}" "${cur_mirror}" || return 1
		fi

		get_pad mirror_pad "${cur_mirror}" 8
		msg_mirr=
		[ -n "${cur_mirror}" ] && msg_mirr=" [   mirror: ${cur_mirror}${mirror_pad} ]"

		rm -f "${rogue_el_file}" "${part_stats_file}" "${ucl_err_file}" "${adg_allow_file}" "${adg_imp_file}" "${adg_skip_file}" "${oversize_file}"
		rogue_element='' # set only if this attempt's rogue elements check finds one

		msg="Processing ${format} blockset part"
		get_pad pad "${msg}" 30
		get_pad print_id_pad "${print_id}" 42

		reg_msg "${msg}: ${pad}${lblue}${print_id}${n_c}${msg_mirr:+"${print_id_pad}"}${msg_mirr}"

		# Download or cat the part
		${fetch_cmd} "${feed_path}" |

		# Limit size
		{
			head -c "${max_part_size:?}k"
			if read -rn1 -d ''
			then cat 1>/dev/null; : > "${oversize_file}"; false
			else :
			fi
		} |

		# Remove BOM, comments, cosmetic rules and whitespaces
		sanitize_part |

		# Convert hosts or AdGuard syntax to raw format
		${format_conv_or_cat} |

		# Count bytes and entries
		tee >(wc -wc > "${part_stats_file}") |

		# Convert to lowercase
		${case_conv_or_cat} |

		# check lists for rogue elements
		# (the trailing ':' keeps this subshell, and with it the pipe to the next stage, open until sed is done:
		# the pipeline does not wait for a process substitution, and the result is read right after it)
		tee >(${SED_CMD} -nE "/${val_entry_regex}/d;p;:1 n;b1" > "${rogue_el_file}"; :) |

		# compress or cat
		${part_compr_or_cat} > "${dest_file}"

		pipeline_rv=${?}

		# read stats
		read_str_from_file -n 64 -v "part_cnt part_size_B _" -f "${part_stats_file}" -a 2 -D "list stats" || return 1

		# size-exceeded check
		[ $(( part_size_B <= max_part_size*1024 )) = 1 ] ||
		{
			set_fail_reason size
			return 4
		}

		if [ "${pipeline_rv}" = 0 ]
		then
			# rogue elements check
			if [ -s "${rogue_el_file}" ]
			then
				read_str_from_file -d -n 512 -F "" -v "rogue_element" -f "${rogue_el_file}" -q -a 2 -D "rogue element"
				local rogue_el_print
				if [ -n "${rogue_element}" ]
				then
					rogue_el_print="Rogue element '${rogue_element}'"
				else
					rogue_el_print="Unknown rogue element"
				fi

				case "${rogue_element}" in *"${CR}"*)
					log_msg -warn "blockset part '${print_id}' contains Non-Unix (CR) newlines." \
						"This file needs to be converted to Unix newline style (LF)."
						set_fail_reason content
						return 3 ;;
				esac

				log_msg -warn "${rogue_el_print} identified in blockset part '${print_id}'."
				[ -n "${rogue_element}" ] || { set_fail_reason content; return 3; }
			fi

			# min_part_entries check
			int2human cnt_human "${part_cnt}" &&
			local lines_cnt_low=
			if [ "${origin}" = DL ] && [ "${part_cnt}" -lt "${min_part_entries}" ]
			then
				lines_cnt_low=1
				int2human min_part_entries_human "${min_part_entries}" || return 1
				reg_fail "Entries count in downloaded blockset part '${print_id}' is ${cnt_human}, which is less than configured minimum: ${min_part_entries_human}."
			fi
		fi

		[ "${pipeline_rv}" = 0 ] || pipeline_msg="Processing pipeline returned code ${pipeline_rv}."
		if [ "${origin}" = DL ] &&
		{
			[ "${pipeline_rv}" != 0 ] ||
			[ -n "${lines_cnt_low}" ] ||
			[ -n "${rogue_element}" ] ||
			! grep -q "Download completed" "${ucl_err_file}"
		}
		then
			if [ -f "${oversize_file}" ]
			then fail_reason=size
			elif ! grep -q "Download completed" "${ucl_err_file}"
			then
				fail_reason="$(${SED_CMD} -n 's/.*HTTP error \([0-9][0-9]*\).*/http_\1/p' "${ucl_err_file}" | tail -n1)"
				fail_reason="${fail_reason:-net}"
			elif [ "${pipeline_rv}" != 0 ]
			then fail_reason=error
			elif [ -n "${rogue_element}" ]
			then fail_reason=content
			else fail_reason=few
			fi
			set_fail_reason "${fail_reason}"
			[ -s "${ucl_err_file}" ] && ucl_err=" uclient-fetch output: ${_NL_}'$(cat "${ucl_err_file}")'."
			rm -f "${ucl_err_file}"
			reg_fail "" "Failed download attempt for list '${print_id}'.${pipeline_msg:+ }${pipeline_msg}${ucl_err}"
			[ -n "${ucl_err}" ] && log_msg "${ucl_err}"
		elif [ "${pipeline_rv}" != 0 ]
		then
			reg_fail "" "${pipeline_msg}"
			if [ -f "${oversize_file}" ]
			then set_fail_reason size
			else set_fail_reason error
			fi
			return 1
		else
			bytes2human part_size_human "${part_size_B}" -p
			get_pad stats_pad "${print_id}" 42
			get_pad suffix_pad "${cnt_human}" 9
			log_msg "Successfully processed part:    ${green}${print_id}${n_c} ${stats_pad}[ ${orange}${part_size_human}${n_c}  - ${suffix_pad}${orange}${cnt_human} entries${n_c} ]"
			if [ "${format}" = adguard ]
			then
				read_str_from_file -n 32 -v adg_skipped -f "${adg_skip_file}" -a 1 -q
				[ "${adg_skipped:-0}" != 0 ] &&
					log_msg "Skipped ${adg_skipped} AdGuard rule(s) that can not be expressed in dnsmasq (wildcards, regexes, unsupported modifiers) in part '${print_id}'."
				rm -f "${adg_skip_file}"
			fi

			rm -f "${ucl_err_file}"
			# set this mirror as forced if this is not the first DL attempt
			[ "${origin}" = DL ] && [ -n "${feed_author}" ] && [ "${attempt}" != 1 ] &&
				printf '%s\n' "${cur_mirror}" > "${PROCESSED_PARTS_DIR}/${feed_author}-forced-mirror"
			return 0
		fi

		incr attempt
		if [ ! "${attempt}" -le "${max_download_attempts}" ]
		then
			reg_fail "${max_download_attempts} download attempts failed for list '${print_id}'."
			return 2
		fi

		log_msg -yellow "" "Processing job for list '${print_id}' is sleeping for 5 seconds after failed download attempt."
		sleep 5 &
		wait ${!}

		if [ "${origin}" = DL ] && [ -n "${feed_author}" ]
		then
			# cycle to the next mirror
			next_mirror='' loop_prev_mirror=''
			for mirror in ${mirrors}
			do
				[ "${loop_prev_mirror}" = "${cur_mirror}" ] && { next_mirror="${mirror}"; break; }
				loop_prev_mirror="${mirror}"
			done
			cur_mirror="${next_mirror:-"${first_mirror}"}"
		fi
	done
}

part_size_exceeded()
{
	reg_fail "Size of blockset part '${1}' exceeded the maximum value set in config option 'max_part_size_KB' (${2} KB)."
	log_msg "Consider either increasing this value in the blockset config or removing the corresponding blockset part identifier or URL from same config."
}

# ${LIST_STATUS_F}:
#   run <epoch> <1: the new blockset was installed | 0: it was not>
#   list <ok|fail> <last attempt epoch> <last good epoch, 0: never> <entries> <reason|-> <list id>
# Both writers replace the file in one move and never fail the update.
# A list is recorded as failed only if an attempt of its job failed: one never started, or stopped before
# that, because of another list (blockset_part_failed_action=STOP) keeps its earlier record.
# 1: part indexes
save_list_status()
{
	local index print_id cnt reason state now \
		old="${LIST_STATUS_F:?}" new="${ABL_TMP_DIR:?}/list-status"

	now="$(date +%s)"
	for index in ${1}
	do
		print_id='' cnt='' reason=- state=ok
		job_get_params "${index}" print_id && [ -n "${print_id}" ] || continue
		[ -f "${PROCESSED_PARTS_DIR}/${index}_stats" ] && read -r cnt _ < "${PROCESSED_PARTS_DIR}/${index}_stats"
		case "${cnt}" in
			''|*[!0-9]*)
				[ -f "${PROCESSED_PARTS_DIR}/${index}_fail" ] || continue
				cnt=0 state=fail
				read -r reason < "${PROCESSED_PARTS_DIR}/${index}_fail"
		esac
		printf '%s %s %s %s\n' "${state}" "${cnt}" "${reason:-error}" "${print_id}"
	done > "${new}"

	# lists not processed this time are kept for 30 days
	[ -f "${old}" ] || old=/dev/null
	${AWK_CMD:?} -v now="${now}" '
		FILENAME == ARGV[1] {
			if ($1 == "run") print
			else if ($1 == "list") { line[$7] = $0; at[$7] = $3; good[$7] = $4; ids[++n] = $7 }
			next
		}
		$1 == "ok" || $1 == "fail" {
			print "list", $1, now, ($1 == "ok" ? now : (($4 in good) ? good[$4] : 0)), $2, $3, $4
			seen[$4] = 1
		}
		END {
			for (i = 1; i <= n; i++)
				if (!(ids[i] in seen) && at[ids[i]] > now - 2592000) { print line[ids[i]]; seen[ids[i]] = 1 }
		}' "${old}" "${new}" > "${LIST_STATUS_F}.tmp" &&
		mv -f "${LIST_STATUS_F}.tmp" "${LIST_STATUS_F}" ||
		rm -f "${LIST_STATUS_F}.tmp"
	rm -f "${new}"
	:
}

# 1: 1 if the newly generated blockset(s) got installed, else 0
save_run_status()
{
	local old="${LIST_STATUS_F:?}"
	[ -f "${old}" ] || old=/dev/null
	{ printf 'run %s %s\n' "$(date +%s)" "${1}" && ${AWK_CMD:?} '$1 == "list"' "${old}"; } > "${LIST_STATUS_F}.tmp" &&
		mv -f "${LIST_STATUS_F}.tmp" "${LIST_STATUS_F}" ||
		rm -f "${LIST_STATUS_F}.tmp"
	:
}

# shellcheck disable=SC2329
gen_set_parts()
{
	processing_done_cb()
	{
		local \
			index \
			failed \
			dest_file \
			part_stats_file \
			fail_jobs="${4}" \
			unfinished_jobs="${5}" \
			undispatched_jobs="${6}" \
			expired_jobs="${7}" \
			aborted_jobs="${8}"

		[ "${?}" = 0 ] || return ${?}

		# the IDs must stay apart: '1' and '2' glued together would name job 12
		failed="${fail_jobs} ${unfinished_jobs} ${undispatched_jobs} ${expired_jobs} ${aborted_jobs}"

		case "${failed}" in *[!\ ]*) ;; *) return 0 ;; esac

		for index in ${failed}
		do
			job_get_params "${index}" part_stats_file dest_file || return 1
			rm -f "${dest_file}"
			printf 'FAIL 0\n' > "${part_stats_file}"
		done

		return 0
	}

	part_done_cb()
	{
		local indexes abort_sets set_id \
			abort_indexes abort_sets \
			index="${1}" rv="${2}"

		# vars delivered by the scheduler
		assert_set F_part_done_cb print_id dest_file part_stats_file max_part_size || exit 1

		[ "${rv}" = 0 ] ||
		{
			rm -f "${dest_file}" "${part_stats_file}"
			# the job did not say why it failed (timed out, or died)
			[ -f "${PROCESSED_PARTS_DIR}/${index}_fail" ] ||
			{
				if [ "${rv}" = 124 ]
				then printf 'timeout\n'
				else printf 'error\n'
				fi > "${PROCESSED_PARTS_DIR}/${index}_fail"
			}
		}

		case "${rv}" in
			0) return 0 ;;
			1)
				if [ -n "${print_id}" ]
				then
					reg_fail "Fatal error in processing job for list '${print_id}'."
				else
					reg_fail "Fatal error reported by unknown processing job."
				fi
				return 1
		esac

		if [ "${rv}" = 4 ]
		then
			part_size_exceeded "${print_id}" "${max_part_size}"
		else
			reg_fail "" "Processing job for list '${print_id:-unknown}' returned error code '${rv}'."
		fi

		for set_id in ${PROC_SET_IDS}
		do
			eval "indexes=\"\${set_indexes_${set_id}}\""
			is_included "${index}" "${indexes}" || continue
			[ "${blockset_part_failed_action}" = STOP ] &&
			{
				abl_append abort_sets "${set_id}"
				add2list abort_indexes "${indexes}"
				continue
			}
		done

		[ -n "${abort_sets}" ] &&
		{
			log_msg -ob "${abort_sets}" "" "blockset_part_failed_action is set to 'STOP'. Stopping processing{}."
			jobs_abort ${abort_indexes}
		}

		return 0
	}

	# shellcheck disable=SC2034
	SCHEDULER_PID=
	local \
		me=gen_set_parts \
		part_type part_indexes indexes \
		set_ids="${1:?}"

	assert_set "F_${me}" ALL_PART_TYPES || return 1

	# clean up before processing
	rm -rf "${PROCESSED_PARTS_DIR}"

	try_mkdir -p "${PROCESSED_PARTS_DIR}" || return 1

	reg_action -1 -purple "" "Downloading and processing blockset parts (max parallel jobs: ${PARALLEL_JOBS})."

	# Asynchronously download and process parts, allowlist must be processed separately and first
	for part_type in ${ALL_PART_TYPES}
	do
		eval "part_indexes=\"\${indexes_${part_type}}\""
		[ -n "${part_indexes}" ] || continue
		add2list indexes "${part_indexes}"
	done

	assert_set "F_${me}" indexes || return 1

	DO_JOB_CB=process_set_part \
	JOB_DONE_CB=part_done_cb \
	SCHED_FINALIZE_CB=processing_done_cb \
	SCHED_FAIL_MSG_CB=reg_fail \
	SCHED_MAX_JOBS="${PARALLEL_JOBS}" \
	SCHED_TIMEOUT_S=900 \
	SCHED_IDLE_TIMEOUT_S=500 \
	SCHED_JOB_TIMEOUT_S=300 \
	SCHED_AUTO_JOB_TERM=1 \
		schedule_jobs "${indexes}" &

	SCHEDULER_PID=${!}

	wait "${SCHEDULER_PID}"
	local sched_rv=${?}
	SCHEDULER_PID=
	save_list_status "${indexes}"
	return ${sched_rv}
}

gen_blocksets()
{
	local \
		me=gen_blocksets \
		IFS="${DEFAULT_IFS}" \
		processed_set_file \
		part \
		set_id \
		run_state \
		cur_path \
		cur_cnt \
		cur_persist_path \
		cur_persist_cnt \
		conn_check_req \
		file_to_bk \
		bk_path bk_cnt bk_ext \
		bk_path_prev bk_cnt_prev \
		final_compr_ext \
		blocksets_to_stop \
		force_unload_bl \
		force_unload="${unload_blockset_before_update:?}" \
		install_path \
		totalmem \
		TESTED_URLS \
		SCHED_ID=process \
		\
		raw_block_lists \
		hosts_block_lists \
		adguard_block_lists \
		local_part \
		\
		part_type \
		format \
		index=0 \
		set_indexes \
		blocksets_out_var="${1:?}" set_ids="${2:?}"

	reg_msg -fb "${set_ids}" "" "Preparing to generate blockset file(s){}."

	if [ "${force_unload}" = auto ]
	then
		read -r _ totalmem _ < /proc/meminfo
		if is_gr_eq 410000 "${totalmem}"
		then
			force_unload=0
		else
			force_unload=1
		fi
	fi

	# Prepare processing for all blocksets
	local dl_parts
	for format in ${ALL_PART_FORMATS:?}
	do
		local "all_process_parts_${format}="

		for part_type in ${ALL_PART_TYPES}
		do
			local "indexes_${part_type}="

			# hosts and adguard formats are only valid for type 'block'
			# (exceptions in adguard-format lists are extracted from the block part)
			case "${format}" in hosts|adguard) [ "${part_type}" != block ] && continue; esac

			for set_id in ${set_ids}
			do
				local "set_indexes_${set_id}="
				get_params "${set_id}" \
					"dl_parts=${format}_${part_type}_lists" \
					"local_part=local_${part_type}list_path"

				{ [ -n "${local_part}" ] && [ -f "${local_part}" ]; } ||
					set_params "${set_id}" "local_${part_type}list_path="

				[ -n "${dl_parts}${local_part}" ] || continue

				[ -n "${dl_parts}" ] &&
				{
					invalid_urls="$(printf %s "${dl_parts}" | tr ' ' '\n' | grep -E '^(http[s]*://)*(www\.)*github\.com')" &&
					{
						reg_fail "Invalid URLs detected:" "${invalid_urls}"
						return 1
					}

					[ "${format}" = raw ] &&
					{
						bad_hagezi_urls="$(printf %s "${dl_parts}" | tr ' ' '\n' | grep '/hagezi/.*/dnsmasq/')" &&
						{
							reg_fail "Following Hagezi lists are in dnsmasq format and should be changed to raw-format lists:" "${bad_hagezi_urls}"
							return 1
						}
						case "${part_type}" in block|allow)
							bad_hagezi_urls="$(
								printf %s "${dl_parts}" |
								tr ' ' '\n' |
								${SED_CMD} -En '/(raw.githubusercontent.com\/hagezi\/dns-blocklists\/|gitlab.com\/hagezi\/mirror\/)/{/onlydomains\./d;/\/(nrd|dga)[0-9][0-9-]*\.txt$/d;p;}'
							)"
							[ -z "${bad_hagezi_urls}" ] ||
							{
								reg_fail "Following Hagezi URLs are missing the '-onlydomains' suffix in the filename:" \
									"${bad_hagezi_urls}"
								return 1
							}
						esac
					}
				}

				for part in ${dl_parts}
				do
					add2list "all_process_parts_${format}" "${part}" "${_NL_}"
				done
				# local lists are raw-format: process them once, not once per format
				[ -n "${local_part}" ] && [ "${format}" = raw ] && add2list "all_process_parts_${format}" "local=${local_part}" "${_NL_}"
			done
		done
	done

	local \
		PROC_SET_IDS \
		all_process_parts \
		max_part_size \
		max_part_size_prev \
		min_part_entries \
		min_part_entries_prev \
		dest_file \
		is_ipv4 \
		is_ipv4_prev

	for format in ${ALL_PART_FORMATS:?}
	do
		eval "all_process_parts=\"\${all_process_parts_${format}}\""
		[ -n "${all_process_parts}" ] || continue

		debug_msg "all_process_parts_${format}: '${all_process_parts}'"

		IFS="${_NL_}"
		for part in ${all_process_parts}
		do
			[ -n "${part}" ] || continue

			IFS="${DEFAULT_IFS}"
			incr index
			export -n "INDEX_REFS_${index}="

			origin=DL
			case "${part}" in local=*)
				origin=LOCAL
			esac

			get_part_process_path dest_file "${index}"
			job_set_params "${index}" \
				"format=${format}" \
				"origin=${origin}" \
				"print_id=${part#"local="}" \
				"dest_file=${dest_file}" \
				"part_stats_file=${PROCESSED_PARTS_DIR}/${index}_stats"

			for part_type in ${ALL_PART_TYPES:?}
			do
				# hosts and adguard formats are only valid for type 'block'
				case "${format}" in hosts|adguard) [ "${part_type}" != block ] && continue; esac

				case "${part_type}" in
					ipv4_*) is_ipv4=1 ;;
					*) is_ipv4=0 ;;
				esac
				eval "min_part_entries=\"\${min_${part_type}_part_entries}\""
				assert_set "F_${me}" min_part_entries || return 1

				for set_id in ${set_ids}
				do
					get_params "${set_id}" \
						max_part_size \
						"dl_parts=${format}_${part_type}_lists" \
						"local_part=local_${part_type}list_path"

					[ -n "${dl_parts}${local_part}" ] || continue

					is_included "${part}" "${dl_parts}" ||
					{ [ -n "${local_part}" ] && [ "${part}" = "local=${local_part}" ]; } ||
						continue

					# min_part_entries may be different if same feed is used as allow- in one blockset but as block- in another
					job_get_params "${index}" \
						"max_part_size_prev=max_part_size" \
						"min_part_entries_prev=min_part_entries" \
						"is_ipv4_prev=is_ipv4"

					[ -n "${is_ipv4_prev}" ] && [ "${is_ipv4}" != "${is_ipv4_prev}" ] &&
						{ reg_fail "Blockset part '${part#"local="}' is specified as both ipv4 and not."; return 1; }

					[ -n "${min_part_entries_prev}" ] &&
					[ "${min_part_entries_prev}" -lt "${min_part_entries}" ] &&
						min_part_entries=${min_part_entries_prev}

					[ -n "${max_part_size_prev}" ] &&
					[ "${max_part_size_prev}" -gt "${max_part_size}" ] &&
						max_part_size=${max_part_size_prev}

					job_set_params "${index}" \
						"max_part_size=${max_part_size}" \
						"min_part_entries=${min_part_entries}" \
						"is_ipv4=${is_ipv4}" \
						"part_type_${set_id}=${part_type}"

					abl_append "indexes_${part_type}" "${index}"
					abl_append "set_indexes_${set_id}" "${index}"
					add2list "INDEX_REFS_${index}" "${set_id}"
					add2list PROC_SET_IDS "${set_id}"
				done
			done
		done
		IFS="${DEFAULT_IFS}"
	done

	[ -n "${PROC_SET_IDS}" ] || { reg_fail "Nothing to process."; return 1; }

	for set_id in ${set_ids}
	do
		is_included "${set_id}" "${PROC_SET_IDS}" || { reg_fail -fb "${set_id}" "Nothing to process{}."; continue; }
		debug_msg "Processing bockset ${set_id}."
		get_params -f "${me}" "${set_id}" run_state || return 1
		get_params "${set_id}" \
			cur_path \
			cur_cnt \
			cur_persist_path \
			cur_persist_cnt \
			bk_path_prev=bk_path \
			bk_cnt_prev=bk_cnt \
			bk_ext \
			raw_block_lists \
			hosts_block_lists \
			adguard_block_lists

		[ -n "${raw_block_lists}${hosts_block_lists}${adguard_block_lists}" ] ||
			log_msg -yellow "" "NOTE: No URLs specified for blocklist download."

		conn_check_req=1
		force_unload_bl=${force_unload}

		case "${run_state}" in
			0) ;;
			3|4) force_unload_bl=0 conn_check_req='' ;;
			*) reg_fail -fb "${set_id}" "${me}: unexpected run state '${run_state}'{}."; exit 1
		esac

		[ "${force_unload_bl}" = 1 ] ||
		[ -z "${conn_check_req}" ] ||
		test_fetch_doms "${set_id}" ||
			force_unload_bl=1

		[ "${force_unload_bl}" = 1 ] &&
			add2list blocksets_to_stop "${set_id}"

		bk_cnt=
		bk_path=
		file_to_bk=

		if [ -n "${bk_path_prev}" ] && [ -n "${bk_cnt_prev}" ] && [ -f "${bk_path_prev}" ]
		then
			bk_path=${bk_path_prev}
			bk_cnt=${bk_cnt_prev}
		elif [ -n "${cur_path}" ] && [ -n "${cur_cnt}" ] && [ -f "${cur_path}" ]
		then
			file_to_bk=${cur_path}
			bk_cnt=${cur_cnt}
		elif [ -n "${cur_persist_path}" ] && [ -n "${cur_persist_cnt}" ] && [ -f "${cur_persist_path}" ]
		then
			file_to_bk=${cur_persist_path}
			bk_cnt=${cur_persist_cnt}
		fi

		[ -n "${file_to_bk}" ] && [ -f "${file_to_bk}" ] || file_to_bk=

		if [ -n "${file_to_bk}" ] &&
			is_dir_writable "${set_id}" "${file_to_bk%/*}"
		then
			bk_path="${BK_SET_BASE_PATH:?}-${set_id}${bk_ext}"
			reg_action -fb "${set_id}" "" "Creating backup of current blockset file{}."
			mv_blockset "${file_to_bk}" "${bk_path}" "${INTERM_COMPR_TO_FILE}" "${set_id}" ||
			{
				reg_fail "Failed to create backup of current blockset file '${file_to_bk}'."
				rm_if_writable "${set_id}" "${file_to_bk}"
				bk_path=
				bk_cnt=
			}
		elif [ -n "${file_to_bk}" ]
		then
			# for persistent blockset in 'manual' mode, the original file is used as a backup
			bk_path="${file_to_bk}"
		elif [ -z "${bk_path}" ]
		then
			reg_msg -2 -fb "${set_id}" "No existing blockset file found{}."
		fi
		set_params "${set_id}" bk_path bk_cnt
	done

	KEEP_BK=1 KEEP_MNGD_PERSIST=0 rm_blocksets "${PROC_SET_IDS}"
	[ -z "${blocksets_to_stop}" ] || KEEP_BK=1 KEEP_MNGD_PERSIST=0 do_stop "${blocksets_to_stop}" || exit 1

	gen_set_parts "${set_ids}" ||
	{
		reg_fail "Failed to generate blockset parts."
		return 1
	}

	for set_id in ${PROC_SET_IDS}
	do
		eval "set_indexes=\"\${set_indexes_${set_id}}\""
		get_params -f "${me}" "${set_id}" install_path || return 1
		get_params "${set_id}" final_compr_ext

		processed_set_file="${ABL_TMP_DIR}/processed-${set_id}${final_compr_ext}"

		if gen_blockset "${set_id}" "${processed_set_file}" "${set_indexes}" &&
			try_mv "${processed_set_file}" "${install_path}"
		then
			add2list "${blocksets_out_var}" "${set_id}"
			debug_msg "install_path: ${install_path};"
		else
			rm -f "${processed_set_file}"
			reg_fail -fb "${set_id}" "Failed to generate new blockset file{}."
		fi
	done
}


# 1: blockset ID
# 2: output file path
# shellcheck disable=SC2329
gen_blockset()
{
	# domains listed in ${adg_keep_f} ($important AdGuard block rules) are never removed
	rm_allow_domains()
	{
		${AWK_CMD:?} 'FILENAME == ARGV[1] { if ($0 ~ /^\*\./) { allow_wild[substr($0,3)]; next }; allow[$0]; next }
			FILENAME == ARGV[2] { keep[$0]; next }
			($1 in keep) { print; next }
			{ n=split($1,arr,"."); addr = arr[n]; for ( i=n-1; i>=1; i-- )
			{ addr = arr[i] "." addr; if ( (i>1 && addr in allow_wild) || addr in allow ) next } } 1' \
				"${merged_allow_f:?}" "${adg_keep_f:?}" -
	}

	# deduplication that also counts, for each block list, the entries no other list of the set has.
	# input: '<domain> <part index>' lines (print_set_parts ... tag). Prints every domain once and writes
	# '<part index> <count>' lines to ${proc_dir}/uniq_stats (no line for a list with none).
	# C locale: ' ' must sort before every domain character, so all lines of a domain are adjacent.
	# Domains are compared as strings ('$1 ""'): entries like '1.1' and '1.10' are equal as numbers
	dedup_count_uniq()
	{
		LC_ALL=C ${SORT_CMD:?} -u |
		${AWK_CMD:?} -v F="${proc_dir:?}/uniq_stats" '
			{ k = $1 "" }
			k != d { if (n == 1) u[i]++; if (NR > 1) print d; d = k; n = 0 }
			{ n++; i = $2 }
			END { if (NR) { if (n == 1) u[i]++; print d }; for (j in u) print j, u[j] > F }'
	}

	whitelist_filter()
	{
		# only print subdomains of allowlist domains
		${AWK_CMD:?} 'NR==FNR { if ($0 !~ /^\*/) { allow[$0] }; next } { n=split($1,arr,"."); addr = arr[n];
			for ( i=n-1; i>1; i-- ) { addr = arr[i] "." addr; if ( addr in allow ) { print $1; next } } }' "${merged_allow_f:?}" -
	}

	# convert to dnsmasq format and pack 4 input lines into 1 output line
	# intput from STDIN, output to STDOUT
	# 1 - block|allow
	pack_entries_sed()
	{
		case "$1" in
			block)
				# packs 4 domains in one 'local=/.../' line
				${SED_CMD:?} "/^$/d;s~^.*$~local=/&/~;\$!{n;a /${_NL_}};\$!{n;a /${_NL_}};\$!{n; a /${_NL_}};a @" ;;
			allow)
				# packs 4 domains in one 'server=/.../#'' line
				{ cat; printf '\n'; } | ${SED_CMD:?} '/^$/d;$!N;$!N;$!N;s~\n~/~g;s~^~server=/~;s~/*$~/#@~' ;;
			*) printf ''; return 1
		esac | tr -d '\n' | tr "@" '\n'
	}

	# convert to dnsmasq format and pack input lines into 1024 characters-long lines
	# intput from STDIN, output to STDOUT
	# 1 - block|allow
	pack_entries_awk()
	{
		local entry_type len_lim=1024 allow_char
		case "$1" in
			block) entry_type=local ;;
			allow) entry_type=server allow_char="#" ;;
		esac

		len_lim=$((len_lim-${#entry_type}-${#allow_char}-2))
		${AWK_CMD:?} -v ORS="" -v M="${len_lim}" -v A="${allow_char}" -v T="${entry_type}" '
			BEGIN {al=0; r=0; s=""}
			NF {
				r=r+1
				if (r==1) {print T "=/"}
				l=length($0)
				n=al+1+l
				if (n<=M) {al=n; print $0 "/"; next}
				else {print A "\n" T "=/" $0 "/"; al=l+1}
			}
			END {print A "\n"}'
	}

	rm_indexed_part()
	{
		local index part_file index_refs
		for index in ${2}
		do
			eval "index_refs=\"\${INDEX_REFS_${index}}\""
			subtract_a_from_b "${1}" "${index_refs}" index_refs
			export -n "INDEX_REFS_${index}=${index_refs}"
			[ -n "${index_refs}" ] && continue
			get_part_process_path part_file "${index}"
			rm -f "${part_file}"
		done
	}

	# 1 - part indexes, 2 - (optional) 'tag': append ' <part index>' to every entry, for dedup_count_uniq()
	print_set_parts()
	{
		local index index_refs part_file rv \
			indexes="${1:?}"

		for index in ${indexes}
		do
			get_part_process_path part_file "${index}"
			if [ "${2}" = tag ]
			then
				${PART_EXTR_OR_CAT_STDOUT:?} "${part_file}" | ${SED_CMD:?} "/^\$/d;s/\$/ ${index}/"
			else
				${PART_EXTR_OR_CAT_STDOUT:?} "${part_file}"
			fi
			rv=${?}
			eval "index_refs=\"\${INDEX_REFS_${index}}\""
			[ -z "${index_refs}" ] && rm -f "${part_file}"
			[ ${rv} = 0 ] || { printf ''; reg_fail "Failed command: '${PART_EXTR_OR_CAT_STDOUT:?} ${part_file}'."; return 1; }
		done
	}

	local me=gen_blockset \
		min_entries min_entries_human \
		max_part_size \
		max_set_size \
		errors \
		dedup_cmd_or_cat="${CAT_CMD:?}" \
		block_dedup_or_cat="${CAT_CMD:?}" \
		block_parts_tag='' \
		allow_filter_or_cat="${CAT_CMD:?}" \
		pack_cmd="pack_entries_sed" \
		final_compr_or_cat_stdout \
		use_allowlist use_ipv4_blocklist \
		merged_allow_f \
		proc_dir \
		test_domains \
		whitelist_mode \
		\
		set_id="${1:?}" \
		out_f="${2:?}" \
		set_indexes="${3:?}"

	proc_dir="${ABL_TMP_DIR}/process-${set_id}"
	merged_allow_f="${proc_dir}/allow"

	rm -rf "${proc_dir}"

	reg_action -purple -fb "${set_id}" "" "Generating blockset file{}."

	get_params -f "${me}" "${set_id}" \
		max_part_size \
		max_set_size \
		min_entries=min_blockset_entries \
		final_compr_or_cat_stdout || return 1

	get_params "${set_id}" \
		test_domains \
		whitelist_mode

	debug_msg "${me}: ${set_id}: set_indexes:${set_indexes}; out_f:${out_f};"

	case "${PART_EXTR_OR_CAT_STDOUT:?}" in
		"${CAT_CMD:?}") ;;
		*) assert_set "F_${me}" INTERM_COMPR_EXT || return 1
	esac

	local max_size_b=$((max_set_size*1024))
	[ "${deduplication}" = 1 ] &&
	{
		dedup_cmd_or_cat="${SORT_CMD} -u -"
		block_dedup_or_cat=dedup_count_uniq
		block_parts_tag=tag
	}

	case "${AWK_CMD:?}" in
		*gawk) pack_cmd="pack_entries_awk"
	esac

	# shellcheck disable=SC2034
	# Process results
	local part_cnt part_size_B part_size_B_human list_cnt_raw list_cnt_raw_human part_size_B index part_type print_id index_refs \
		set_cnt_raw=0 set_size_B_raw=0 allow_cnt_raw=0 block_cnt_raw=0 ipv4_block_cnt_raw=0 \
		set_cnt_raw_human set_size_B_raw_human set_size_B set_size_B_human \
		block_indexes allow_indexes ipv4_block_indexes

	for index in ${set_indexes}
	do
		eval "index_refs=\"\${INDEX_REFS_${index}}\""
		subtract_a_from_b "${set_id}" "${index_refs}" "INDEX_REFS_${index}"

		[ -s "${PROCESSED_PARTS_DIR}/${index}_stats" ] || { reg_fail "${me}: can not find file '${PROCESSED_PARTS_DIR}/${index}_stats'."; return 1; }

		job_get_params "${index}" print_id "part_type=part_type_${set_id}" &&
		[ -n "${part_type}" ] &&
		read_str_from_file -n 64 -v "part_cnt part_size_B" -f "${PROCESSED_PARTS_DIR}/${index}_stats" -V 0 &&
		{
			[ "${part_cnt}" != FAIL ] || continue
		} &&
		is_uint "${part_cnt}" "${part_size_B}" ||
			{ reg_fail "Failed to read processed stats for blockset part with index ${index} (ID '${print_id}', type '${part_type}')."; return 1; }

		# This second part size check is necessary because download-time limit is against max of all sets
		[ $(( part_size_B <= max_part_size*1024)) = 1 ] ||
		{
			rm_indexed_part "${set_id}" "${index}"
			part_size_exceeded "${print_id}" "${max_part_size}"
			if [ "${blockset_part_failed_action}" = STOP ]
			then
				log_msg -ob "${set_id}" "blockset_part_failed_action is set to 'STOP'. Stopping processing{}."
				rm_indexed_part "${set_id}" "${set_indexes}"
				return 1
			elif [ "${set_indexes}" = "${index}" ]
			then
				log_msg -ib "${set_id}" "Failed to generate the only part{}."
				return 1
			else
				log_msg "blockset_part_failed_action is set to 'SKIP'. Skipping part and continuing.."
				continue
			fi
		}

		incr set_cnt_raw part_cnt
		incr set_size_B_raw part_size_B
		incr "${part_type}_cnt_raw" part_cnt
		incr "${part_type}_size_B" part_size_B
		abl_append "${part_type}_indexes" "${index}"
	done

	[ "${set_cnt_raw}" -gt 0 ] ||
		{ reg_fail -fb "${set_id}" "Failed to generate preprocessed files with at least one entry{}."; return 1; }

	bytes2human set_size_B_raw_human "${set_size_B_raw}" &&
	int2human set_cnt_raw_human "${set_cnt_raw}" || return 1

	reg_msg "Uncompressed blockset parts size: ${orange}${set_size_B_raw_human}${n_c}, entries count: ${orange}${set_cnt_raw_human}${n_c}."

	try_mkdir -p "${proc_dir}" || return 1

	for part_type in ${ALL_PART_TYPES}
	do
		# count entries for current list type
		eval "list_cnt_raw=\"\${${part_type}_cnt_raw:-0}\"" \
			"part_size_B=\"\${${part_type}_size_B:-0}\""

		if ! [ "${list_cnt_raw}" -gt 0 ] || ! [ "${part_size_B}" -gt 0 ]
		then
			[ "${part_type}" = block ] &&
			{
				[ "${whitelist_mode}" = 1 ] || {
					bytes2human part_size_B_human "${part_size_B:-0}"
					int2human list_cnt_raw_human "${list_cnt_raw:-0}"
					reg_fail "Total entries count and size of block-entries: ${list_cnt_raw_human}, ${part_size_B_human}."
					return 1
				}
				log_msg -yellow "Whitelist mode is on - accepting empty blocklist."
			}
		elif [ "${part_type}" = ipv4_block ]
		then
			use_ipv4_blocklist=1
		elif [ "${part_type}" = allow ]
		then
			print_set_parts "${allow_indexes}" |
			# optional deduplication
			${dedup_cmd_or_cat} >> "${merged_allow_f}" || return 1
			use_allowlist=1
		fi
	done

	# add exceptions (@@ rules) extracted from adguard-format block parts
	# - not in whitelist mode (they would whitelist third-party domains)
	# - an exception never covers a domain (or a parent of a domain) from the user's local blocklist
	# - $important block rules are kept even if an exception covers them (adg_keep_f, see rm_allow_domains)
	local adg_allow_f adg_allow_cnt local_blocklist_path \
		adg_keep_f="${proc_dir}/adg_important"
	: > "${adg_keep_f}" || return 1
	get_params "${set_id}" local_blocklist_path
	[ "${whitelist_mode}" = 1 ] ||
	for index in ${block_indexes}
	do
		[ -s "${PROCESSED_PARTS_DIR}/${index}_adg_important" ] &&
			cat "${PROCESSED_PARTS_DIR}/${index}_adg_important" >> "${adg_keep_f}"
		adg_allow_f="${PROCESSED_PARTS_DIR}/${index}_adg_allow"
		[ -s "${adg_allow_f}" ] || continue
		if [ -n "${local_blocklist_path}" ] && [ -s "${local_blocklist_path}" ]
		then
			${AWK_CMD:?} 'FILENAME == ARGV[1] { d = tolower($1); sub(/^\*\./, "", d); n = split(d, a, ".");
					s = a[n]; for (i = n - 1; i >= 1; i--) { s = a[i] "." s; covered[s] }; next }
				!($0 in covered)' "${local_blocklist_path}" "${adg_allow_f}"
		else
			cat "${adg_allow_f}"
		fi > "${adg_allow_f}.tmp" || return 1
		adg_allow_cnt="$(wc -l < "${adg_allow_f}.tmp")"
		cat "${adg_allow_f}.tmp" >> "${merged_allow_f}" || return 1
		rm -f "${adg_allow_f}.tmp"
		job_get_params "${index}" print_id
		reg_msg "Added ${adg_allow_cnt// /} exception(s) from AdGuard-format part '${print_id}' to the allowlist."
		use_allowlist=1
	done

	case "${use_allowlist}" in
		1) reg_msg "Will remove any (sub)domain matches present in the allowlist from the blockset and append corresponding server entries to the blockset." ;;
		*) reg_msg "Not using any allowlist for blockset processing."
	esac

	reg_msg "Sorting and merging blockset parts into a single blockset file."

	case "${whitelist_mode}" in
	1)
		# only print subdomains of allowlist domains
		use_allowlist=1
		printf '%s\n' ${test_domains} >> "${merged_allow_f}"
		allow_filter_or_cat=whitelist_filter ;;
	*)
		[ "${use_allowlist}" = 1 ] &&
		# remove allowlist domains from blockset
		allow_filter_or_cat=rm_allow_domains
	esac


	# Blockset generation pipeline
	{
		{
			# print blockset parts
			print_set_parts "${block_indexes}" ${block_parts_tag} |
			# optional deduplication (with the count of entries only one list has)
			${block_dedup_or_cat} |

			# Optionally remove allow domains or enforce whitelist-only mode
			${allow_filter_or_cat} |

			# count entries
			tee >(wc -w > "${proc_dir}/block_stats") |

			# pack entries in 1024 characters long lines
			${pack_cmd} block || exit 1

			# print ipv4 blockset parts
			if [ -n "${use_ipv4_blocklist}" ]
			then
				print_set_parts "${ipv4_block_indexes}" |
				# optional deduplication
				${dedup_cmd_or_cat} |
				tee >(wc -w > "${proc_dir}/ipv4_block_stats") |
				# add prefix
				${SED_CMD} 's/^/bogus-nxdomain=/' || exit 1
			fi

			# print allowlist parts
			if [ "${use_allowlist}" = 1 ]
			then
				# optional deduplication
				${dedup_cmd_or_cat} < "${merged_allow_f}" |
				tee >(wc -w > "${proc_dir}/allow_stats") |
				# pack entries in 1024 characters long lines
				${pack_cmd} allow || exit 1

				rm -f "${merged_allow_f}"
			fi

			# add the optional whitelist entry
			if [ "${whitelist_mode}" = 1 ]
			then
				# add block-everything entry: local=/*a/*b/*c/.../*z/
				printf 'local=/'
				${AWK_CMD} 'BEGIN{for (i=97; i<=122; i++) printf("*%c/",i);exit}' || exit 1
				printf '\n'
			fi

			# add the test domain, keyed on the blockset ID
			printf '%s\n' "address=/${set_id}-${ABL_TEST_DOM_BASE}/#"
		} |

		# limit size
		{ head -c "${max_size_b}"; read -rn1 -d '' && { touch "${proc_dir}/abl-too-big.tmp"; cat 1>/dev/null; } || true; } |

		# compress or cat
		${final_compr_or_cat_stdout} > "${out_f}"
	} 2>"${ERR_F}" ||
		{
			reg_fail "Failed to merge blockset parts into output file '${out_f}'."
			errors="$(cat "${ERR_F}" 2>/dev/null | ${SED_CMD} '/^$/d')"
			rm -f "${out_f}" "${ERR_F}"
			[ -n "${errors}" ] && log_msg "STDERR output:${_NL_}${errors}"
			return 1
		}

	rm -f "${ERR_F}"

	if [ -f "${proc_dir}/abl-too-big.tmp" ]
	then
		rm -f "${out_f}"
		reg_fail -fb "${set_id}" "Final uncompressed blockset file size{} exceeded ${max_set_size} kiB set in max_blockset_size_KB config option!"
		log_msg "Consider either increasing this value in the config or changing the blockset URLs."
		return 1
	fi

	# for the web interface: how many entries of each block list no other list of the set has
	if [ -n "${block_parts_tag}" ]
	then
		local uniq_cnt uniq_cnt_human
		for index in ${block_indexes}
		do
			job_get_params "${index}" print_id && [ -n "${print_id}" ] || continue
			uniq_cnt="$(${AWK_CMD} -v i="${index}" '$1 == i { print $2 }' "${proc_dir}/uniq_stats" 2>/dev/null)"
			is_uint "${uniq_cnt}" || uniq_cnt=0
			int2human uniq_cnt_human "${uniq_cnt}"
			log_msg "Entries no other list has:    ${green}${print_id}${n_c}   [ ${orange}${uniq_cnt_human}${n_c} ]"
		done
		rm -f "${proc_dir}/uniq_stats"
	fi

	# check total entries count vs min_entries
	local read_cnt block_cnt ipv4_block_cnt allow_cnt \
		gen_cnt=0 gen_cnt_human
	for part_type in block ipv4_block allow
	do
		read_cnt=0
		read -r read_cnt 2>/dev/null < "${proc_dir}/${part_type}_stats"
		local "${part_type}_cnt=${read_cnt:-0}"
	done

	gen_cnt=$(( block_cnt + ipv4_block_cnt + allow_cnt ))

	[ "${whitelist_mode}" = 1 ] && gen_cnt=$((gen_cnt-26)) # ignore alphabet entries

	is_uint "${gen_cnt}" || gen_cnt=0

	int2human gen_cnt_human "${gen_cnt}" || return 1

	if [ "${gen_cnt}" -lt "${min_entries}" ]
	then
		int2human min_entries_human "${min_entries}" || return 1
		reg_fail "Entries count (${gen_cnt_human}) is below the minimum value set in config option 'min_blockset_entries' (${min_entries_human})."
		return 1
	fi

	# check the final blockset with dnsmasq --test
	reg_action "Checking the processed blockset file with '${DMSQ_CMD:?} --test'."

	rm -f "${ERR_F}"

	{
		try_extract -stdout "${out_f}" |
		${DMSQ_CMD:?} --test -C -
	} 2> "${ERR_F}"

	if [ ${?} != 0 ] || ! grep -q "syntax check OK" "${ERR_F}"
	then
		errors="$(head -n10 "${ERR_F}" | ${SED_CMD} '/^$/d')"
		rm -f "${ERR_F}" "${out_f}"
		reg_fail "dnsmasq test on the processed blockset failed."
		log_msg "Errors:" "${errors:-"No specifics: probably killed because of OOM."}"
		return 2
	fi

	rm -f "${ERR_F}"

	set_size_B=$(get_file_size "${out_f}")
	bytes2human set_size_B_human "${set_size_B:-0}"

	local comp_pr=compressed
	case "${final_compr_or_cat_stdout}" in
		cat|*" cat"|*/cat) comp_pr=uncompressed
	esac

	reg_msg "${green}Final blockset file check passed${n_c} (${comp_pr}, ${orange}${set_size_B_human}${n_c}, ${orange}${gen_cnt_human} entries${n_c})"

	set_params "${set_id}" install_cnt="${gen_cnt}"

	:
}

:
