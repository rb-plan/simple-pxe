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
