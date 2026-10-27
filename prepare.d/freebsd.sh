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
		&& -s "${dir}/boot/kernel/kernel" && -s "${dir}/SHA256" ]]
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

			# The NFS root is patched into loader_pxe.efi as ${PXE_NFS_ROOT}/<relpath>
			# (here: freebsd/<ver>_<arch>), a path that is stable across re-runs.
			mapfile -t loc < <(grep -obUaP "\x2f\x00{127}" "${efi_loader}" | cut -d: -f1)
			(( ${#loc[@]} == 1 ))

			printf '%s\x00' "${PXE_NFS_ROOT}/${relpath}" \
				| dd of="${pxe_loader}" bs=1 seek="${loc[0]}" conv=notrunc status=none

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
