#!/bin/bash
# Generator for ipxe/boot.ipxe, the single network boot menu (iPXE >= 1.21 / 2.x).
# Sourced by ./simple-pxe (action "ipxe-menu", called from boot/build-tftp-stage.sh) so it sees
# the effective Debian mirror settings; do not run it directly.
#
#   ./simple-pxe ipxe-menu [output-file]        (default: stdout)
#
# Entries follow what exists in the data tree and what menu.d/*.sh would offer in GRUB:
#   Debian installer (+firmware)   menu.d/debian.sh   (netboot cache / mirror, preseed.txt)
#   Debian diskless                menu.d/diskless-debian.sh
#   FreeBSD <ver>                  freebsd/<ver>_amd64/{loader_pxe.efi,pxeboot} on TFTP (only the
#                                  versions listed in FREEBSD_VERSIONS)
#   extra entries                  boot/ipxe/entries.d/*.sh fragments
#   GRUB (fallback), iPXE shell, reboot
#
# Variables (config.local): PXE_IPXE_TITLE (default PXE_TITLE), PXE_IPXE_DEFAULT (item name,
# default the first Debian entry), PXE_IPXE_TIMEOUT (seconds, 0 = wait forever, default 10),
# PXE_IPXE_DEBIAN_SUITES (default DEBIAN_LOCAL_SUITES = "bookworm trixie"),
# PXE_IPXE_GRUB (1/0, default 1), PXE_IPXE_ENTRIES_DIR (extra fragment dir), PXE_DISKLESS_DEBIAN[_DIR|_ARGS|_TITLE], PXE_IMAGES_URL.

gen_boot_ipxe() {
	local out="${1:-}" tmp
	tmp="$(mktemp)"

	local http_host http_base title timeout default_item debian_suites
	http_host="$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"${PXE_HTTP_ROOT}")"
	http_base="${PXE_HTTP_ROOT}"
	title="${PXE_IPXE_TITLE:-${PXE_TITLE:-ncosbit Network Boot}}"
	timeout="${PXE_IPXE_TIMEOUT:-10}"
	default_item="${PXE_IPXE_DEFAULT:-}"
	debian_suites="${PXE_IPXE_DEBIAN_SUITES:-${DEBIAN_LOCAL_SUITES:-bookworm trixie}}"

	local -a items=() blocks=()
	local n=0 key

	add_gap() { items+=("item --gap -- $1"); }
	# add_item NAME LABEL [KEY]  (body lines follow on stdin, appended after ":NAME");
	# without KEY the entries are numbered 1..9
	add_item() {
		local name="$1" label="$2"
		if [[ -n "${3:-}" ]]; then
			key="--key $3 "
		else
			n=$((n + 1))
			if ((n <= 9)); then key="--key ${n} "; else key=""; fi
		fi
		items+=("item ${key}${name} ${label}")
		blocks+=(":${name}"$'\n'"$(cat)")
		[[ -z "${default_item}" ]] && default_item="${name}"
	}

	# --- Debian installers -------------------------------------------------------------
	local dl_ok=0
	[[ " ${DEBIAN_ARCHES:-amd64} " == *" amd64 "* ]] && dl_ok=1
	local rl="${PXE_LOCAL_ROOT}/debian/release-list"
	if ((dl_ok)) && [[ -s "${rl}" ]]; then
		local gap_done=0 codename status version major
		local kernel_url initrd_url fw_url preseed label
		preseed="${http_base}/debian/preseed.txt"
		while read -r codename status version; do
			[[ " ${debian_suites} " == *" ${codename} "* ]] || continue
			((gap_done)) || { add_gap "Debian"; gap_done=1; }
			major="${version%%.*}"
			label="Debian ${major:+${major} }${codename}"

			# Same choice as menu.d/debian.sh: the local netboot cache unless the hub's own
			# mirror is in use (installer kernel must match that mirror's udebs), else the mirror.
			local dir="${PXE_LOCAL_ROOT}/debian/netboot/${codename}/amd64"
			if [[ "${DEBIAN_USE_LOCAL_MIRROR}" != 1 && -s "${dir}/linux" && -s "${dir}/initrd.gz" ]]; then
				kernel_url="${http_base}/debian/netboot/${codename}/amd64/linux"
				initrd_url="${http_base}/debian/netboot/${codename}/amd64/initrd.gz"
			else
				local di="${DEBIAN_MIRROR}/dists/${codename}/main/installer-amd64/current/images/netboot/debian-installer/amd64"
				kernel_url="${di}/linux"
				initrd_url="${di}/initrd.gz"
			fi
			fw_url=""
			[[ -s "${PXE_LOCAL_ROOT}/debian/firmware/${codename}/firmware.cpio.gz" ]] \
				&& fw_url="${http_base}/debian/firmware/${codename}/firmware.cpio.gz"

			add_item "deb-${codename}" "${label} installer" <<-EOF
				imgfree
				kernel ${kernel_url} url=${preseed} || goto failed
				initrd ${initrd_url} || goto failed
				boot || goto failed
				goto failed
			EOF
			if [[ -n "${fw_url}" ]]; then
				add_item "deb-${codename}-fw" "${label} installer +firmware" <<-EOF
					imgfree
					kernel ${kernel_url} url=${preseed} || goto failed
					initrd ${initrd_url} || goto failed
					initrd ${fw_url} || goto failed
					boot || goto failed
					goto failed
				EOF
			fi
		done < <(sort -k3,3nr -k2,2 "${rl}")
	fi

	# --- Debian diskless ---------------------------------------------------------------
	local dl_dir dl_url dl_args dl_title dl_enabled
	dl_dir="${PXE_DISKLESS_DEBIAN_DIR:-debian-trixie-diskless}"
	dl_url="${PXE_IMAGES_URL:-http://${http_host}/images}/${dl_dir}/current"
	dl_args="${PXE_DISKLESS_DEBIAN_ARGS:-boot=live fetch=${dl_url}/filesystem.squashfs ip=dhcp}"
	dl_title="${PXE_DISKLESS_DEBIAN_TITLE:-Debian trixie diskless (RAM, ssh key login)}"
	dl_enabled="${PXE_DISKLESS_DEBIAN:-auto}"
	if [[ "${dl_enabled}" == auto ]]; then
		[[ -s "${PXE_IMAGES_ROOT:-/srv/pxe-images}/${dl_dir}/current/vmlinuz" ]] && dl_enabled=1 || dl_enabled=0
	fi
	if [[ "${dl_enabled}" == 1 ]]; then
		add_gap "Diskless"
		# ${diskless_args}: optional extra kernel arguments (e.g. console=ttyS0,115200n8) set
		# by the per-machine script ipxe/mac-<mac>.ipxe
		add_item diskless-debian "${dl_title}" <<-EOF
			imgfree
			kernel ${dl_url}/vmlinuz ${dl_args} \${diskless_args} || goto failed
			initrd ${dl_url}/initrd.img || goto failed
			boot || goto failed
			goto failed
		EOF
	fi

	# --- FreeBSD (patched loaders on TFTP, staged by build-tftp-stage.sh) -----------------
	local folder fb_gap=0 ver
	while read -r folder; do
		ver="${folder%%_*}"
		((fb_gap)) || { add_gap "FreeBSD"; fb_gap=1; }
		add_item "freebsd-${ver}" "FreeBSD ${ver} (NFS root installer)" <<-EOF
			iseq \${platform} efi || goto freebsd-${ver}-bios
			chain tftp://\${srv}/freebsd/${folder}/loader_pxe.efi || goto failed
			goto failed
			:freebsd-${ver}-bios
			chain --name pxeboot.pxe tftp://\${srv}/freebsd/${folder}/pxeboot || goto failed
			goto failed
		EOF
	done < <(freebsd_published_folders)

	# --- Extra entries -------------------------------------------------------------------
	# Every boot/ipxe/entries.d/*.sh (and ${PXE_IPXE_ENTRIES_DIR}/*.sh) is sourced here, in
	# name order, with add_gap / add_item and the variables of this function in scope. This is
	# how further systems (e.g. a FreeBSD diskless image) are added; see entries.d/README.md.
	local frag
	for frag in "${PXE_IPXE_ENTRIES_DIR:-}"/*.sh "$(dirname -- "${BASH_SOURCE[0]}")"/ipxe/entries.d/*.sh; do
		[[ -f "${frag}" ]] || continue
		# shellcheck source=/dev/null
		source "${frag}"
	done

	# --- Fallbacks / tools ---------------------------------------------------------------
	add_gap "Other"
	if [[ "${PXE_IPXE_GRUB:-1}" == 1 ]]; then
		add_item grub "Legacy GRUB menu (fallback)" g <<-EOF
			iseq \${platform} efi || goto grub-bios
			chain tftp://\${srv}/grub/x86_64-efi/grubnetx64-ipxe.efi || goto failed
			goto failed
			:grub-bios
			chain --name core.pxe tftp://\${srv}/grub/i386-pc/core-ipxe.0 || goto failed
			goto failed
		EOF
	fi
	items+=("item --key s shell iPXE shell")
	blocks+=(":shell"$'\n'"shell"$'\n'"goto start")
	items+=("item --key r reboot Reboot")
	blocks+=(":reboot"$'\n'"reboot")

	{
		cat <<-EOF
			#!ipxe
			# Generated by boot/gen-boot-ipxe.sh (./simple-pxe ipxe-menu); do not edit.
			# Needs iPXE >= 1.21 (UEFI initrd support); built by boot/ipxe/build.sh.
			:start
			isset \${srv} || set srv \${next-server}
			isset \${srv} || set srv ${http_host}
			# Optional per-machine settings: ipxe/mac-aa-bb-cc-dd-ee-ff.ipxe (e.g. set diskless_args console=ttyS0,115200n8)
			isset \${mac} && chain tftp://\${srv}/ipxe/mac-\${mac:hexhyp}.ipxe || goto menu
			:menu
			menu ${title}
		EOF
		printf '%s\n' "${items[@]}"
		if [[ "${timeout}" == 0 ]]; then
			echo "choose --default ${default_item} target || goto shell"
		else
			echo "choose --default ${default_item} --timeout $((timeout * 1000)) target || goto shell"
		fi
		echo 'goto ${target}'
		printf '%s\n' "${blocks[@]}"
		cat <<-EOF
			:failed
			echo Boot failed - see the message above. Is the image built and are TFTP/HTTP reachable?
			prompt Press any key to return to the menu
			goto start
		EOF
	} >"${tmp}"
	if [[ -n "${out}" ]]; then
		install -m644 "${tmp}" "${out}"
	else
		cat "${tmp}"
	fi
	rm -f "${tmp}"
}
