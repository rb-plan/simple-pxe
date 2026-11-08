#!/bin/bash
# Deploy the iPXE boot menu: regenerate ipxe/boot.ipxe, rebuild the TFTP stage and install
# ipxe/* into the TFTP root, keeping a backup of the boot.ipxe being replaced.
#
#   boot/deploy-menu.sh            regenerate + install (asks sudo for the install step)
#   boot/deploy-menu.sh -n         dry run: regenerate the stage and show the diff, install nothing
#
# Only the files in <stage>/ipxe/ (boot.ipxe, undionly.kpxe, snponly.efi, ipxe.pxe) are copied,
# one by one: nothing else under the TFTP root is touched or deleted (per-machine
# ipxe/mac-*.ipxe files, freebsd/, openbsd/, ...). Use the rsync from boot/README.md only when
# the other stage files (OpenBSD, GRUB, FreeBSD loaders) changed too.
# Backups: ${PXE_LOCAL_ROOT}/ipxe-menu-backups/boot.ipxe.<timestamp> (last 20 kept).
# Env: TFTP_ROOT (default /srv/tftp).

set -euo pipefail

cd "$(dirname -- "$0")/.."
source config.local

DRY=0
case "${1:-}" in
	-n | --dry-run) DRY=1 ;;
	"") ;;
	*) echo "usage: $0 [-n]" >&2; exit 2 ;;
esac

TFTP_ROOT="${TFTP_ROOT:-/srv/tftp}"
STAGE="${PXE_TFTP_STAGE:-${PXE_LOCAL_ROOT}/tftp-stage}"
DEST="${TFTP_ROOT}/ipxe"
BACKUPS="${PXE_LOCAL_ROOT}/ipxe-menu-backups"
SUDO=""
[[ -w "${DEST}" ]] || SUDO="sudo"

echo "== rebuilding stage ${STAGE}"
boot/build-tftp-stage.sh >/dev/null

NEW="${STAGE}/ipxe/boot.ipxe"
[[ -s "${NEW}" ]] || { echo "ERROR: ${NEW} missing or empty" >&2; exit 1; }
grep -q '^menu ' "${NEW}" || { echo "ERROR: ${NEW} has no menu" >&2; exit 1; }
for f in undionly.kpxe snponly.efi; do
	[[ -s "${STAGE}/ipxe/${f}" ]] || { echo "ERROR: ${STAGE}/ipxe/${f} missing (boot/ipxe/build.sh)" >&2; exit 1; }
done

echo "== menu items"
grep -E '^item ' "${NEW}" | sed -E 's/^item --gap -- /  -- /; t; s/^item --key (.) /  [\1] /'

if [[ -f "${DEST}/boot.ipxe" ]] && cmp -s "${NEW}" "${DEST}/boot.ipxe"; then
	echo "== boot.ipxe unchanged in ${DEST}"
else
	echo "== boot.ipxe changes (${DEST} -> new)"
	diff -u "${DEST}/boot.ipxe" "${NEW}" | tail -n +3 || true
fi

if ((DRY)); then
	echo "== dry run: nothing installed"
	exit 0
fi

if [[ -f "${DEST}/boot.ipxe" ]]; then
	mkdir -p "${BACKUPS}"
	bak="${BACKUPS}/boot.ipxe.$(date +%Y%m%d-%H%M%S)"
	cp -p "${DEST}/boot.ipxe" "${bak}"
	echo "== backup of the old menu: ${bak}"
	# shellcheck disable=SC2012
	ls -1t "${BACKUPS}"/boot.ipxe.* | tail -n +21 | xargs -r rm -f --
fi

echo "== installing into ${DEST}"
${SUDO} install -d -m 755 "${DEST}"
for f in "${STAGE}"/ipxe/*; do
	[[ -f "${f}" ]] || continue
	${SUDO} install -m 644 "${f}" "${DEST}/$(basename -- "${f}")"
	echo "  $(basename -- "${f}")"
done
cmp -s "${NEW}" "${DEST}/boot.ipxe" || { echo "ERROR: install verification failed" >&2; exit 1; }
echo "== done: clients get the new menu on their next boot"
