#!/bin/bash
# Helpers shared by functions.sh (menu.d/*.sh, simple-pxe), boot/gen-boot-ipxe.sh and
# boot/build-tftp-stage.sh. Sourced only.

# freebsd_published_folders: tree folder names (<ver>_<arch>, newest first) that are published
# (menus, TFTP stage). FREEBSD_VERSIONS selects them; trees of other versions that still exist
# under ${PXE_LOCAL_ROOT}/freebsd are ignored. With FREEBSD_VERSIONS unset every tree is published.
# Only complete trees (NFS-patched loaders present) are listed.
freebsd_published_folders() {
	local root="${PXE_LOCAL_ROOT}/freebsd" folder ver arch
	while read -r folder; do
		ver="${folder%%_*}"
		arch="${folder#*_}"
		[[ "${arch}" == amd64 ]] || continue
		if [[ -n "${FREEBSD_VERSIONS:-}" ]]; then
			[[ " $(tr -s ' ,' '  ' <<<"${FREEBSD_VERSIONS}") " == *" ${ver} "* ]] || continue
		fi
		[[ -s "${root}/${folder}/boot/pxeboot_nfs" && -s "${root}/${folder}/boot/loader_pxe.efi" \
			&& -s "${root}/${folder}/boot/kernel/kernel" ]] || continue
		echo "${folder}"
	done < <(find "${root}" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*_*' -printf '%f\n' 2>/dev/null | sort -t_ -k1,1Vr)
}

# openbsd_defaults: defaults for the OpenBSD network install (prepare.d/openbsd.sh,
# boot/openbsd/stage-tftp.sh, boot/ipxe/entries.d/openbsd.sh). Only one version is staged on
# TFTP (/etc/boot.conf is a fixed path there and names the kernel to boot).
openbsd_defaults() {
	: "${OPENBSD_VERSION:=8.0}"
	: "${OPENBSD_MIRROR:=https://cdn.openbsd.org/pub/OpenBSD}"
	: "${OPENBSD_CONSOLE:=com0}"
	: "${OPENBSD_COM0_SPEED:=115200}"
	OPENBSD_NODOT="${OPENBSD_VERSION//./}"
}

# openbsd_published: succeeds when the OpenBSD installer files are published under
# ${PXE_LOCAL_ROOT}/openbsd/<ver>/amd64 (prepare.d/openbsd.sh).
openbsd_published() {
	openbsd_defaults
	local d="${PXE_LOCAL_ROOT}/openbsd/${OPENBSD_VERSION}/amd64"
	[[ -s "${d}/pxeboot" && -s "${d}/BOOTX64.EFI" && -s "${d}/bsd.rd" && -s "${d}/SHA256.sig" ]]
}
