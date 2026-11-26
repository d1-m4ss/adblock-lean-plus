#!/bin/sh
# adblock-lean-plus installer. Runs on the OpenWrt router itself, or on your computer (over SSH).
# git is not needed on either side: a downloaded and unpacked archive of the repository is enough.
#
#   sh install.sh [options]                on the router
#   ./install.sh [options] root@<router>   on your computer
#
# Components (the blocker is always installed):
#   --gui          LuCI pages: Services -> Adblock-lean (subscriptions, schedule, status)
#   --doh          https-dns-proxy with three DoH upstreams (Cloudflare, AdGuard unfiltered, Quad9)
#   --doh-gui      also luci-app-https-dns-proxy (LuCI page for the DoH upstreams); implies --doh
# Blockset:
#   --instance N   dnsmasq instance to filter (default: the only one; required when there are several)
#   --preset P     mini|small|medium|large|huge: adblock-lean's list/size presets (default: chosen from the
#                  router's RAM as adblock-lean does; 'huge' = HaGeZi Pro + TIF full, for 1 GB routers)
#   --lists adguard  add AdGuard DNS filter and AdGuard Popup Hosts to the preset's HaGeZi lists
#   --persist      keep the blockset on flash: filtering right after boot, but the file (several MB) is
#                  rewritten on every update; for routers with eMMC/SSD or a USB stick
# After install:
#   --start        download the lists and load them into dnsmasq now
#   --enable       start at boot (also installs the early boot filter and the sysupgrade keep-file)
# Other:
#   --upgrade      replace the scripts of an existing installation (configs are kept)
#   --dry-run      check the router and print the plan; change nothing
# SSH: one connection is reused for all steps (ControlMaster); extra options in SSH_OPTS.
#
# The installer never changes dnsmasq's port or upstream servers and never touches the firewall:
# pointing dnsmasq at the DoH proxies and taking over port 53 from another resolver are listed at
# the end as commands to run yourself (see README, "If you already run AdGuard Home").
# SSH options can be passed in SSH_OPTS, e.g. SSH_OPTS="-p 2222 -i ~/.ssh/router".
set -eu

usage() { sed -n '2,/^set -eu$/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

HERE=$(cd "$(dirname "$0")" && pwd)
GUI=0 DOH=0 DOH_GUI=0 INSTANCE='' PRESET='' LISTS='' PERSIST=0 START=0 ENABLE=0 UPGRADE=0 DRY=0 HOST=''
while [ $# -gt 0 ]; do
	case "$1" in
		--gui) GUI=1 ;;
		--doh) DOH=1 ;;
		--doh-gui) DOH=1 DOH_GUI=1 ;;
		--instance) INSTANCE=${2:?--instance needs a name}; shift ;;
		--preset) PRESET=${2:?--preset needs a name}; shift ;;
		--lists) LISTS=${2:?--lists needs adguard}; shift ;;
		--persist) PERSIST=1 ;;
		--start) START=1 ;;
		--enable) ENABLE=1 ;;
		--upgrade) UPGRADE=1 ;;
		--dry-run) DRY=1 ;;
		-h|--help) usage 0 ;;
		-*) echo "unknown option: $1" >&2; usage 1 ;;
		*) [ -z "$HOST" ] || { echo "only one router address" >&2; exit 1; }; HOST=$1 ;;
	esac
	shift
done
[ -n "$HOST" ] || [ -f /etc/openwrt_release ] || usage 1
case "$LISTS" in ''|adguard) ;; *) echo "--lists: only 'adguard' is supported" >&2; exit 1 ;; esac
case "$PRESET" in ''|mini|small|medium|large|huge) ;; *) echo "--preset: mini, small, medium, large or huge" >&2; exit 1 ;; esac
case "$INSTANCE" in *[!A-Za-z0-9_]*) echo "--instance: letters, digits and _ only" >&2; exit 1 ;; esac

FILES="adblock-lean/adblock-lean adblock-lean/usr adblock-lean/etc luci-app/luci-app-adblock-lean/root luci-app/luci-app-adblock-lean/htdocs config/https-dns-proxy tools/remote-install.sh"
for f in $FILES; do
	[ -e "$HERE/$f" ] || { echo "missing $f: run install.sh from a full checkout" >&2; exit 1; }
done

set -- "GUI=$GUI" "DOH=$DOH" "DOH_GUI=$DOH_GUI" "INSTANCE=$INSTANCE" "PRESET=$PRESET" "LISTS=$LISTS" "PERSIST=$PERSIST" \
	"START=$START" "ENABLE=$ENABLE" "UPGRADE=$UPGRADE" "DRY=$DRY"

# no router address: we are on the router, install from this directory
[ -n "$HOST" ] || exec sh "$HERE/tools/remote-install.sh" "$@"

# short path: a Unix socket path must stay under ~104 bytes (macOS TMPDIR can be long)
CTL=$(mktemp -u /tmp/ablp-ssh.XXXXXX)
trap 'ssh -o ControlPath="$CTL" -O exit "$HOST" >/dev/null 2>&1 || true' EXIT
# shellcheck disable=SC2086
ssh_r() { ssh ${SSH_OPTS:-} -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=120 "$HOST" "$@"; }

# Archive with root ownership and without macOS metadata files (._*); the router extracts without
# restoring owners (tar -o), so nothing on the router gets the local user's uid/gid.
if tar --version 2>/dev/null | grep -q bsdtar; then TAR_OWNER="--uid 0 --gid 0"; else TAR_OWNER="--owner=0 --group=0"; fi
STAGE=/tmp/adblock-lean-plus-install
ARCHIVE=$(mktemp "${TMPDIR:-/tmp}/ablp-archive.XXXXXX")
# shellcheck disable=SC2086
( cd "$HERE" && COPYFILE_DISABLE=1 tar $TAR_OWNER --exclude='._*' --exclude='.DS_Store' -cf - $FILES ) > "$ARCHIVE" ||
	{ rm -f "$ARCHIVE"; echo "could not pack the installation files" >&2; exit 1; }
echo "Copying installation files to $HOST:$STAGE ..."
ssh_r "rm -rf $STAGE && mkdir -p $STAGE && tar -C $STAGE -xof -" < "$ARCHIVE" ||
	{ rm -f "$ARCHIVE"; echo "could not copy the files to the router" >&2; exit 1; }
rm -f "$ARCHIVE"

ssh_r "sh $STAGE/tools/remote-install.sh" "$@"
