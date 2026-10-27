#!/bin/bash
#menu: Debian
#root: debian

source functions.sh
cd "${LOCAL_PATH}" || exit 1

grub_option SP_DEBIAN_ARCH Architecture \
	amd64 amd64 "For most modern PCs" \
	i386  i386  "For very old PCs"

IFS=' ' read -r -a mirrors <<< "${DEBIAN_MIRROR_BACKUP}"
grub_mirror_selector SP_DEBIAN_MIRROR "${DEBIAN_MIRROR}" "${mirrors[@]}"

fmt="(\$mirror_protocol,\$mirror_host)/\$mirror_path/dists/%s/main/installer-\${SP_DEBIAN_ARCH}/current/images/netboot/debian-installer/\${SP_DEBIAN_ARCH}"
while read -r codename status version; do
	mirror_entry() {
		grub_linux_entry \
			"Debian ${codename} (${status}) Installer" \
			"$(printf "${fmt}" "${codename}")/linux" \
			"$(printf "${fmt}" "${codename}")/initrd.gz" \
			"url=${HTTP_PATH}/preseed.txt"
	}

	# Prefer the local netboot cache (see prepare.d/debian.sh) for the
	# architectures it holds; anything else falls back to the mirror.
	keyword=if
	for dir in "netboot/${codename}"/*/; do
		arch=$(basename -- "${dir}")
		[[ -s "${dir}linux" && -s "${dir}initrd.gz" ]] || continue
		echo "${keyword} [ \"\${SP_DEBIAN_ARCH}\" = ${arch} ]; then"
		grub_linux_entry \
			"Debian ${codename} (${status}) Installer [local]" \
			"${GRUB_PATH}/netboot/${codename}/${arch}/linux" \
			"${GRUB_PATH}/netboot/${codename}/${arch}/initrd.gz" \
			"url=${HTTP_PATH}/preseed.txt"
		keyword=elif
	done

	if [[ "${keyword}" == if ]]; then
		mirror_entry
	else
		echo "else"
		mirror_entry
		echo "fi"
	fi
done < <(sort -k3,3nr -k2,2 release-list)

# vim: set ts=4 sw=4 sts=4 noexpandtab nosta:
