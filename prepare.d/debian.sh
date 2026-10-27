#!/bin/bash
#root: debian

source functions.sh
cd "${LOCAL_PATH}" || exit 1

# DEBIAN_MIRROR / DEBIAN_SECURITY_MIRROR are the effective mirrors (the hub's own mirror
# when DEBIAN_USE_LOCAL_MIRROR=1, see ./simple-pxe). The preseed is what the installed
# machine's sources.list is generated from.
mirror_host=$(cut -d/ -f3 <<< "${DEBIAN_MIRROR}")
mirror_dir="/$(cut -d/ -f4- <<< "${DEBIAN_MIRROR}")"
security_host=$(cut -d/ -f3 <<< "${DEBIAN_SECURITY_MIRROR}")
security_dir="/$(cut -d/ -f4- <<< "${DEBIAN_SECURITY_MIRROR}")"

temp[preseed]=$(mktemp)
cat > "${temp[preseed]}" <<- EOF && install -m644 "${temp[preseed]}" preseed.txt
	d-i mirror/country string manual
	d-i mirror/protocol string http
	d-i mirror/http/hostname string ${mirror_host}
	d-i mirror/http/directory string ${mirror_dir}
	d-i mirror/http/proxy string
	d-i apt-setup/services-select multiselect security, updates
	d-i apt-setup/security_host string ${security_host}
	d-i apt-setup/security_path string ${security_dir}
	d-i apt-setup/non-free-firmware boolean true
	d-i apt-setup/contrib boolean false
	d-i apt-setup/non-free boolean false
EOF

# release-list (codename / status / version) always comes from the upstream mirror: the
# local mirror only has codename directories, not the stable/oldstable aliases. When
# upstream is unreachable the previous list is kept so prepare works offline.
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
	done < <(curl -fsL --max-time 30 "${DEBIAN_UPSTREAM_MIRROR}/dists/${status}/Release")
done

if (("${count}" == "${#status_list[@]}")); then
	mv "${temp[rlist]}" "release-list"
elif [[ -s release-list ]]; then
	echo "WARNING: could not refresh the Debian version list from ${DEBIAN_UPSTREAM_MIRROR}; keeping the existing release-list" >&2
else
	panick "Failed to update Debian version list"
fi

# Debian's non-free-firmware installer add-on (firmware.cpio.gz, appended as a second
# initrd by the "+firmware" menu entries). Local-first like the other big assets:
# ${PXE_DOWNLOADS}/debian/firmware/<codename>/{firmware.cpio.gz,SHA256SUMS}; downloaded
# from ${DEBIAN_FIRMWARE_MIRROR}/<codename>/current/ only when missing. It is hard-linked
# (or copied) to firmware/<codename>/firmware.cpio.gz in the served tree, because
# downloads/ is not served over HTTP.
for codename in ${DEBIAN_FIRMWARE_SUITES}; do
	rel_dir="debian/firmware/${codename}"
	fw_url="${DEBIAN_FIRMWARE_MIRROR}/${codename}/current"
	download_local_first "${rel_dir}/SHA256SUMS" "${fw_url}/SHA256SUMS" || true
	if ! download_local_first "${rel_dir}/firmware.cpio.gz" "${fw_url}/firmware.cpio.gz"; then
		echo "Debian firmware: no firmware.cpio.gz for ${codename}; +firmware entry skipped" >&2
		continue
	fi
	verify_sha256 "${PXE_DOWNLOADS}/${rel_dir}/firmware.cpio.gz" "${PXE_DOWNLOADS}/${rel_dir}/SHA256SUMS" firmware.cpio.gz
	mkdir -p "firmware/${codename}"
	if [[ ! -s "firmware/${codename}/firmware.cpio.gz" \
		|| "$(sha256_of "firmware/${codename}/firmware.cpio.gz")" != "${LAST_SHA256}" ]]; then
		ln -f "${PXE_DOWNLOADS}/${rel_dir}/firmware.cpio.gz" "firmware/${codename}/firmware.cpio.gz" 2> /dev/null \
			|| cp -f "${PXE_DOWNLOADS}/${rel_dir}/firmware.cpio.gz" "firmware/${codename}/firmware.cpio.gz"
		chmod 644 "firmware/${codename}/firmware.cpio.gz"
	fi
	echo "${LAST_SHA256}  firmware.cpio.gz" > "firmware/${codename}/SHA256"
	echo "Firmware ready: firmware/${codename}/firmware.cpio.gz"
done

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
