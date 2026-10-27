#!/bin/bash
# Switch the Debian installer menu / preseed between the upstream mirror and the hub's own.
#
#   boot/mirror/use-local-mirror.sh check   # is the local mirror complete enough? (read-only)
#   boot/mirror/use-local-mirror.sh on      # check, then DEBIAN_USE_LOCAL_MIRROR=1 + prepare + menu
#   boot/mirror/use-local-mirror.sh off     # DEBIAN_USE_LOCAL_MIRROR=0 + prepare + menu
#
# The flag lives in config.local; "on"/"off" only edit that one line.

set -euo pipefail
cd "$(dirname -- "$0")/../.."
source config.local

LOCAL="${DEBIAN_LOCAL_MIRROR:?set DEBIAN_LOCAL_MIRROR in config.local}"
SECURITY="${DEBIAN_LOCAL_SECURITY_MIRROR:-${LOCAL%/debian}/debian-security}"
SUITES="${DEBIAN_LOCAL_SUITES:-bookworm trixie}"

check() {
	local bad=0 url
	for suite in ${SUITES}; do
		for url in \
			"${LOCAL}/dists/${suite}/InRelease" \
			"${LOCAL}/dists/${suite}/Release" \
			"${LOCAL}/dists/${suite}/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux" \
			"${LOCAL}/dists/${suite}/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz" \
			"${LOCAL}/dists/${suite}/main/binary-amd64/Packages.xz" \
			"${LOCAL}/dists/${suite}/main/debian-installer/binary-amd64/Packages.xz" \
			"${SECURITY}/dists/${suite}-security/InRelease"; do
			code=$(curl -s -o /dev/null -w '%{http_code}' -I "${url}" || true)
			if [[ "${code}" != 200 ]]; then
				echo "MISSING (${code}): ${url}"
				bad=1
			fi
		done
	done
	((bad == 0)) && echo "local mirror OK for: ${SUITES}"
	return "${bad}"
}

setflag() {
	if grep -q '^DEBIAN_USE_LOCAL_MIRROR=' config.local; then
		sed -i "s/^DEBIAN_USE_LOCAL_MIRROR=.*/DEBIAN_USE_LOCAL_MIRROR=$1/" config.local
	else
		echo "DEBIAN_USE_LOCAL_MIRROR=$1" >> config.local
	fi
	./simple-pxe prepare
	./simple-pxe menu
	echo "DEBIAN_USE_LOCAL_MIRROR=$1 applied (preseed and menus regenerated)"
}

case "${1:-}" in
	check) check ;;
	on) check && setflag 1 ;;
	off) setflag 0 ;;
	*) sed -n '2,/^set -e/p' "$0" | sed '$d' >&2; exit 2 ;;
esac
