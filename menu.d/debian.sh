#!/bin/bash
#menu: Debian
#root: debian

source functions.sh
cd "${LOCAL_PATH}" || exit 1

# Architectures: DEBIAN_ARCHES (default amd64). With one architecture there is nothing
# to choose, so no option submenu is generated.
read -r -a arches <<< "${DEBIAN_ARCHES}"
if (( ${#arches[@]} == 1 )); then
	echo "set SP_DEBIAN_ARCH='${arches[0]}'"
else
	arch_args=()
	for arch in "${arches[@]}"; do
		arch_args+=("${arch}" "${arch}" "")
	done
	grub_option SP_DEBIAN_ARCH Architecture "${arch_args[@]}"
fi

IFS=' ' read -r -a mirrors <<< "${DEBIAN_MIRROR_BACKUP}"
grub_mirror_selector SP_DEBIAN_MIRROR "${DEBIAN_MIRROR}" "${mirrors[@]}"

fmt="(\$mirror_protocol,\$mirror_host)/\$mirror_path/dists/%s/main/installer-\${SP_DEBIAN_ARCH}/current/images/netboot/debian-installer/\${SP_DEBIAN_ARCH}"
while read -r codename status version; do
	# With the hub's own mirror only the mirrored suites can be installed (the preseed
	# points at it); the stale per-suite netboot cache is not used because the installer
	# kernel must match the udebs on the mirror.
	if [[ "${DEBIAN_USE_LOCAL_MIRROR}" == 1 ]]; then
		[[ " ${DEBIAN_LOCAL_SUITES} " == *" ${codename} "* ]] || continue
	fi

	# entry TITLE_SUFFIX [EXTRA_INITRD]: installer from the mirror (anywhere the
	# selected mirror serves it).
	mirror_entry() {
		grub_linux_entry \
			"Debian ${codename} (${status}) Installer${1}" \
			"$(printf "${fmt}" "${codename}")/linux" \
			"$(printf "${fmt}" "${codename}")/initrd.gz${2:+ ${2}}" \
			"url=${HTTP_PATH}/preseed.txt"
	}

	fw=""
	[[ -s "firmware/${codename}/firmware.cpio.gz" ]] && fw="${GRUB_PATH}/firmware/${codename}/firmware.cpio.gz"

	# Prefer the local netboot cache (see prepare.d/debian.sh) for the architectures it
	# holds, unless the hub's mirror is in use; anything else uses the mirror.
	keyword=if
	if [[ "${DEBIAN_USE_LOCAL_MIRROR}" != 1 ]]; then
		for dir in "netboot/${codename}"/*/; do
			arch=$(basename -- "${dir}")
			[[ -s "${dir}linux" && -s "${dir}initrd.gz" ]] || continue
			echo "${keyword} [ \"\${SP_DEBIAN_ARCH}\" = ${arch} ]; then"
			grub_linux_entry \
				"Debian ${codename} (${status}) Installer [local]" \
				"${GRUB_PATH}/netboot/${codename}/${arch}/linux" \
				"${GRUB_PATH}/netboot/${codename}/${arch}/initrd.gz" \
				"url=${HTTP_PATH}/preseed.txt"
			if [[ -n "${fw}" && "${arch}" == amd64 ]]; then
				grub_linux_entry \
					"Debian ${codename} (${status}) Installer [local] +firmware" \
					"${GRUB_PATH}/netboot/${codename}/${arch}/linux" \
					"${GRUB_PATH}/netboot/${codename}/${arch}/initrd.gz ${fw}" \
					"url=${HTTP_PATH}/preseed.txt"
			fi
			keyword=elif
		done
	fi

	if [[ "${keyword}" == if ]]; then
		mirror_entry ""
		if [[ -n "${fw}" ]]; then
			echo "if [ \"\${SP_DEBIAN_ARCH}\" = amd64 ]; then"
			mirror_entry " +firmware" "${fw}"
			echo "fi"
		fi
	else
		echo "else"
		mirror_entry ""
		echo "fi"
	fi
done < <(sort -k3,3nr -k2,2 release-list)

# vim: set ts=4 sw=4 sts=4 noexpandtab nosta:
