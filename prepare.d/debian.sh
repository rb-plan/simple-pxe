#!/bin/bash
#root: debian

source functions.sh
cd "${LOCAL_PATH}" || exit 1

temp[preseed]=$(mktemp)
cat > "${temp[preseed]}" <<- EOF && install -m644 "${temp[preseed]}" preseed.txt
	d-i mirror/country string manual
	d-i mirror/http/hostname string $(cut -d/ -f3 <<< "${DEBIAN_MIRROR}")
	d-i mirror/http/directory string /$(cut -d/ -f4- <<< "${DEBIAN_MIRROR}")
	d-i mirror/http/proxy string
	d-i apt-setup/security_host string $(cut -d/ -f3 <<< "${DEBIAN_MIRROR}")
EOF

temp[rlist]=$(mktemp)
count=0
status_list=(unstable testing stable oldstable oldoldstable)

for status in "${status_list[@]}"; do
	while read -r line; do
		IFS=": " read -r key value <<< "${line}"
		if [[ "${key}" == Version ]]; then
			version="${value}"
		elif [[ "${key}" == Codename ]]; then
			echo -e "${value}\t${status}\t${version}" >> "${temp[rlist]}"
			count=$((count + 1))
			break
		fi
	done < <(curl -fsL "${DEBIAN_MIRROR}/dists/${status}/Release")
done

if (("${count}" == "${#status_list[@]}")); then
	mv "${temp[rlist]}" "release-list"
else
	panick "Failed to update Debian version list"
fi

# Optional local netboot cache (amd64), used by menu.d/debian.sh when present.
# Source: ${PXE_DOWNLOADS}/debian/<suite>/netboot.tar.gz + SHA256SUMS, where
# <suite> is stable/testing/... as listed in release-list. Extracted to
# netboot/<codename>/amd64/{linux,initrd.gz,version.info}.
#   DEBIAN_NETBOOT_CACHE=auto   (default) use local tarballs when present
#   DEBIAN_NETBOOT_CACHE=fetch  also download missing tarballs from ${DEBIAN_MIRROR}
#   DEBIAN_NETBOOT_CACHE=off    disable
netboot_arch=amd64
case "${DEBIAN_NETBOOT_CACHE}" in
	off | 0) ;;
	auto | fetch)
		for suite in ${DEBIAN_NETBOOT_SUITES}; do
			codename=$(awk -v s="${suite}" '$2 == s { print $1; exit }' release-list)
			if [[ -z "${codename}" ]]; then
				echo "Debian netboot cache: suite '${suite}' not in release-list, skipped" >&2
				continue
			fi

			rel_dir="debian/${suite}"
			tarball="${PXE_DOWNLOADS}/${rel_dir}/netboot.tar.gz"
			sumfile="${PXE_DOWNLOADS}/${rel_dir}/SHA256SUMS"
			cache="netboot/${codename}/${netboot_arch}"

			if [[ "${DEBIAN_NETBOOT_CACHE}" == fetch ]]; then
				img_url="${DEBIAN_MIRROR}/dists/${codename}/main/installer-${netboot_arch}/current/images"
				download_local_first "${rel_dir}/SHA256SUMS" "${img_url}/SHA256SUMS" || true
				download_local_first "${rel_dir}/netboot.tar.gz" "${img_url}/netboot/netboot.tar.gz" \
					|| echo "Debian netboot cache: download failed for ${codename}" >&2
			fi

			if [[ ! -s "${tarball}" ]]; then
				echo "Debian netboot cache: no local ${tarball}; ${codename} will use the mirror"
				continue
			fi

			verify_sha256 "${tarball}" "${sumfile}" "netboot/netboot.tar.gz"
			tar_sha="${LAST_SHA256}"

			if [[ -s "${cache}/linux" && -s "${cache}/initrd.gz" && -f "${cache}/SHA256" \
				&& "$(cut -d' ' -f1 "${cache}/SHA256")" == "${tar_sha}" ]]; then
				echo "Up to date: ${cache}"
				continue
			fi

			echo "Extracting ${tarball} to ${cache} (${suite} = ${codename})"
			work="netboot/.tmp.${codename}.${netboot_arch}"
			rm -rf "${work}"
			mkdir -p "${work}"
			if bsdtar -x -f "${tarball}" -C "${work}" \
				"./debian-installer/${netboot_arch}/linux" \
				"./debian-installer/${netboot_arch}/initrd.gz" \
				"./version.info" \
				&& [[ -s "${work}/debian-installer/${netboot_arch}/linux" \
					&& -s "${work}/debian-installer/${netboot_arch}/initrd.gz" ]]; then
				mkdir -p "${work}/out"
				mv "${work}/debian-installer/${netboot_arch}/linux" \
					"${work}/debian-installer/${netboot_arch}/initrd.gz" \
					"${work}/version.info" "${work}/out/"
				echo "${tar_sha}  netboot.tar.gz" > "${work}/out/SHA256"
				chmod 755 "${work}/out"
				chmod 644 "${work}"/out/*
				rm -rf "${cache}"
				mkdir -p "$(dirname -- "${cache}")"
				mv "${work}/out" "${cache}"
				rm -rf "${work}"
			else
				rm -rf "${work}"
				panick "Failed to extract netboot files from %s" "${tarball}"
			fi
		done
		;;
	*)
		panick "Invalid DEBIAN_NETBOOT_CACHE='%s' (use auto, fetch or off)" "${DEBIAN_NETBOOT_CACHE}"
		;;
esac

# vim: set ts=4 sw=4 sts=4 noexpandtab nosta:
