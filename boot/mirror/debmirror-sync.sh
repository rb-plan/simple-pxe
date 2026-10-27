#!/bin/bash
# Partial Debian mirror for the intranet (amd64; bookworm + trixie; updates; security).
#
#   debmirror-sync.sh main|security|all [extra debmirror options, e.g. --dry-run]
#
# Writes to ${MIRROR_ROOT:-/srv/mirror}/debian and .../debian-security, logs to
# ${MIRROR_ROOT}/logs/. Upstream is USTC over rsync. Run as the owner of MIRROR_ROOT
# (not root). A lock keeps main and security syncs (and a manual run) from overlapping.
#
# Scope: arch amd64 (+all); components main contrib non-free-firmware (NOT non-free);
# udebs (main/debian-installer; contrib/non-free-firmware have none) and the d-i installer images are included; no sources,
# no Contents-*, no pdiff files, English translations only.

set -uo pipefail

MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror}"
# USTC's rsync-proxy blocks this host ("@ERROR: Access denied") after debmirror's many
# short rsync connections (seen on the first sync), so HTTP is the default transport.
METHOD="${DEBMIRROR_METHOD:-http}"
UPSTREAM_HOST="${UPSTREAM_HOST:-mirrors.ustc.edu.cn}"
SUITES="${DEBMIRROR_SUITES:-bookworm,bookworm-updates,trixie,trixie-updates}"
DI_SUITES="${DEBMIRROR_DI_SUITES:-bookworm,trixie}"
SECURITY_SUITES="${DEBMIRROR_SECURITY_SUITES:-bookworm-security,trixie-security}"
SECTIONS="main,contrib,non-free-firmware,main/debian-installer"
KEYRING="${DEBMIRROR_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"

what="${1:-all}"
shift || true

mkdir -p "${MIRROR_ROOT}/debian" "${MIRROR_ROOT}/debian-security" "${MIRROR_ROOT}/logs"

# Only the keyring given with --keyring is trusted (no stray ~/.gnupg keys).
export GNUPGHOME=/nonexistent
export TMPDIR="${MIRROR_ROOT}/.tmp"
export PERL5LIB="$(dirname -- "$(readlink -f -- "$0")")/perl${PERL5LIB:+:${PERL5LIB}}"
export PERL5OPT="-MDebmirrorUA${PERL5OPT:+ ${PERL5OPT}}"
mkdir -p "${TMPDIR}"

common=(
	--method="${METHOD}" --host="${UPSTREAM_HOST}" --arch=amd64
	--nosource --i18n --diff=none --postcleanup --keyring="${KEYRING}"
	--exclude='/Contents-.*'
	--timeout=120
	--progress --verbose
)

run() {
	local name="$1" log
	shift
	log="${MIRROR_ROOT}/logs/${name}-$(date +%Y%m%d-%H%M%S).log"
	echo "== $(date -Is) ${name}: start (log: ${log})"
	nice -n 10 ionice -c3 debmirror "$@" >"${log}" 2>&1
	local rc=$?
	echo "== $(date -Is) ${name}: exit ${rc}"
	ln -sfn "$(basename "${log}")" "${MIRROR_ROOT}/logs/${name}-latest.log"
	# keep the last 30 logs per name
	ls -1t "${MIRROR_ROOT}/logs/${name}"-2*.log 2>/dev/null | tail -n +31 | xargs -r rm -f
	return "${rc}"
}

sync_main() {
	run debmirror-debian "${common[@]}" --root=/debian \
		--dist="${SUITES}" --section="${SECTIONS}" \
		--di-dist="${DI_SUITES}" --di-arch=amd64 \
		"$@" "${MIRROR_ROOT}/debian"
}

sync_security() {
	run debmirror-security "${common[@]}" --root=/debian-security \
		--dist="${SECURITY_SUITES}" --section="${SECTIONS}" \
		"$@" "${MIRROR_ROOT}/debian-security"
}

exec 9>"${MIRROR_ROOT}/.sync.lock"
flock -n 9 || { echo "another mirror sync is running (lock ${MIRROR_ROOT}/.sync.lock)" >&2; exit 75; }

rc=0
case "${what}" in
	main) sync_main "$@" || rc=$? ;;
	security) sync_security "$@" || rc=$? ;;
	all) sync_main "$@" || rc=$?; sync_security "$@" || rc=$? ;;
	*) echo "usage: $0 main|security|all [debmirror options]" >&2; exit 2 ;;
esac

if (( rc == 0 )); then
	date -Is > "${MIRROR_ROOT}/.last-sync-ok-${what}"
fi
exit "${rc}"
