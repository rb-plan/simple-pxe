#!/bin/bash
#root: freebsd

source functions.sh
cd "${LOCAL_PATH}" || exit 1

# Versions come from $FREEBSD_VERSIONS (space/comma separated; missing ISOs are
# fetched from $FREEBSD_MIRROR) or, when unset, from local directories named
# ${PXE_DOWNLOADS}/freebsd/<major.minor>/ that contain a disc1.iso.
freebsd_versions() {
	if [[ -n "${FREEBSD_VERSIONS}" ]]; then
		tr -s ' ,' '\n\n' <<< "${FREEBSD_VERSIONS}" | grep -v '^$'
	else
		local dir
		for dir in "${PXE_DOWNLOADS}"/freebsd/*/; do
			compgen -G "${dir}FreeBSD-*-disc1.iso" > /dev/null && basename -- "${dir}"
		done | grep -P '^\d+\.\d+$'
	fi | sort -Vru
}

# A tree is only usable when everything the menu and the PXE loader need exist.
tree_complete() {
	local dir="$1"
	[[ -s "${dir}/cd.iso" && -s "${dir}/boot/loader_pxe.efi" \
		&& -s "${dir}/boot/pxeboot" && -s "${dir}/boot/kernel/kernel" && -s "${dir}/SHA256" ]]
}

# Both loaders ship with a 128-byte "/" rootpath slot (libsa's default NFS root).
# Writing the NFS path into it means no DHCP root-path option is needed; the
# server address comes from DHCP next-server (siaddr).
patch_nfs_root() {
	local src="$1" dst="$2" root="$3" loc
	mapfile -t loc < <(grep -obUaP "\x2f\x00{127}" "${src}" | cut -d: -f1)
	(( ${#loc[@]} == 1 )) || return 1
	[[ "${src}" == "${dst}" ]] || install -m644 "${src}" "${dst}"
	printf '%s\x00' "${root}" | dd of="${dst}" bs=1 seek="${loc[0]}" conv=notrunc status=none
}

# Serial console for the installer (COM1 115200 8N1) next to the screen: the loader reads
# /boot/loader.conf.local from the NFS root, so BIOS (pxeboot starts on VGA only) and UEFI both
# get the loader menu, kernel messages and bsdinstall on ttyS0 too. Same settings as the diskless
# image. FREEBSD_INSTALLER_CONSOLE="" leaves the tree alone.
write_console_conf() {
	local dir="$1" con="${FREEBSD_INSTALLER_CONSOLE-comconsole,efi,vidconsole}"
	[[ -n "${con}" ]] || return 0
	cat > "${dir}/boot/loader.conf.local" <<-EOF
		console="${con}"
		comconsole_speed="115200"
		boot_multicons="YES"
		boot_serial="YES"
	EOF
}

# The loader normally takes the NFS server from the DHCP siaddr of its own request, but
# the DHCP server (not this host) answers that with its own address unless the request
# looks like a PXE client, and the loader then hangs after "Setting currdev". libsa's
# net_parse_rootpath accepts "<ip>:<path>", so bake the server in when it is an IPv4
# address (hostnames are not resolved by the loader).
nfs_rootpath() {
	local rel="$1"
	if [[ "${PXE_NFS_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "${PXE_NFS_HOST}:${PXE_NFS_ROOT}/${rel}"
	else
		echo "${PXE_NFS_ROOT}/${rel}"
	fi
}

mapfile -t versions < <(freebsd_versions)
(( ${#versions[@]} > 0 )) \
	|| panick "No FreeBSD versions: set \$FREEBSD_VERSIONS or put disc1 ISOs under %s/freebsd/<version>/" "${PXE_DOWNLOADS}"

failed=0
for ver in "${versions[@]}"; do
	for arch in ${FREEBSD_ARCHES}; do
		iso_name="FreeBSD-${ver}-RELEASE-${arch}-disc1.iso"
		sum_name="CHECKSUM.SHA256-FreeBSD-${ver}-RELEASE-${arch}"
		rel_dir="freebsd/${ver}"
		base_url="${FREEBSD_MIRROR}/releases/ISO-IMAGES/${ver}"
		iso="${PXE_DOWNLOADS}/${rel_dir}/${iso_name}"
		sumfile="${PXE_DOWNLOADS}/${rel_dir}/${sum_name}"
		target="${ver}_${arch}"

		if [[ ! -s "${iso}" ]]; then
			if [[ -z "${FREEBSD_VERSIONS}" ]]; then
				continue
			fi
			download_local_first "${rel_dir}/${sum_name}" "${base_url}/${sum_name}" || true
			if ! download_local_first "${rel_dir}/${iso_name}" "${base_url}/${iso_name}"; then
				echo "==> ERROR: FreeBSD ${ver} ${arch}: ISO not found locally (${iso}) and download failed" >&2
				failed=1
				continue
			fi
		fi

		verify_sha256 "${iso}" "${sumfile}" "${iso_name}"
		iso_sha="${LAST_SHA256}"

		if tree_complete "${target}" && [[ "$(cut -d' ' -f1 "${target}/SHA256")" == "${iso_sha}" ]]; then
			# Cheap refresh so trees prepared before pxeboot_nfs existed (or after a
			# PXE_NFS_ROOT change) get a correct BIOS loader without a full rebuild.
			nfs_root="$(nfs_rootpath "$(realpath --relative-to="${PXE_LOCAL_ROOT}" "${target}")")"
			patch_nfs_root "${target}/boot/pxeboot" "${target}/boot/pxeboot_nfs" "${nfs_root}" \
				&& patch_nfs_root "${target}/boot/loader.efi" "${target}/boot/loader_pxe.efi" "${nfs_root}" \
				|| { echo "==> ERROR: cannot patch PXE loaders in ${target}" >&2; failed=1; continue; }
			write_console_conf "${target}"
			echo "Up to date: ${target}"
			continue
		fi

		if [[ -e "${target}" ]]; then
			echo "Rebuilding ${target}: incomplete tree or ISO changed"
		fi
		echo "Extracting ${iso} to ${target}"

		id="freebsd_${RANDOM}"
		temp[${id}]=".tmp.${target}"
		rm -rf "${temp[${id}]}"
		(
			set -eo pipefail

			relpath=$(realpath --relative-to="${PXE_LOCAL_ROOT}" "${target}")
			mkdir "${temp[${id}]}" && cd "${temp[${id}]}"

			cp --reflink=auto "${iso}" "cd.iso"
			chmod 644 cd.iso
			bsdtar -x -f "cd.iso" --exclude='usr/' && mkdir usr

			efi_loader="boot/loader.efi"
			pxe_loader="boot/loader_pxe.efi"
			install -m644 "${efi_loader}" "${pxe_loader}"

			true > etc/fstab
			cat >> etc/rc.initdiskless <<- EOF
				mount -t tmpfs tmpfs /mnt
				mkdir /mnt/iso
				mount -t cd9660 /dev/\`mdconfig -f /cd.iso\` /mnt/iso
				for path in bin lib libexec root sbin usr; do
				  mount -t nullfs /mnt/iso/\$path /\$path
				done
				for path in etc var; do
				  eval md_size_\$path=32768
				  create_md \$path
				  cp -Rp /mnt/iso/\$path/ /\$path
				done
				true > /etc/fstab
			EOF

			# The NFS root is patched into the PXE loaders as [${PXE_NFS_HOST}:]${PXE_NFS_ROOT}/<relpath>
			# (here: freebsd/<ver>_<arch>), a path that is stable across re-runs.
			patch_nfs_root "${efi_loader}" "${pxe_loader}" "$(nfs_rootpath "${relpath}")"
			patch_nfs_root boot/pxeboot boot/pxeboot_nfs "$(nfs_rootpath "${relpath}")"

			write_console_conf .
			echo "${iso_sha}  ${iso_name}" > SHA256
		)

		if [[ $? == 0 ]] && tree_complete "${temp[${id}]}"; then
			if [[ -e "${target}" ]]; then
				rm -rf ".old.${target}"
				mv "${target}" ".old.${target}"
			fi
			mv "${temp[${id}]}" "${target}"
			rm -rf ".old.${target}"
		else
			echo "==> ERROR: failed to prepare FreeBSD ${target}" >&2
			rm -rf "${temp[${id}]}"
			failed=1
		fi
	done
done

exit "${failed}"

# vim: set ts=4 sw=4 sts=4 noexpandtab nosta:
