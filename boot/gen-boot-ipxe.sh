#!/bin/bash
# Generator for ipxe/boot.ipxe, the single network boot menu (iPXE >= 1.21 / 2.x).
# Sourced by ./simple-pxe (action "ipxe-menu", called from boot/build-tftp-stage.sh) so it sees
# the effective Debian mirror settings; do not run it directly.
#
#   ./simple-pxe ipxe-menu [output-file]        (default: stdout)
#
# Entries follow what exists in the data tree and what menu.d/*.sh would offer in GRUB, in this
# menu order (the first one is the default):
#   Debian diskless                menu.d/diskless-debian.sh
#   FreeBSD 15.1 diskless          boot/ipxe/entries.d/freebsd-diskless.sh
#   Debian installer (+firmware)   menu.d/debian.sh   (netboot cache / mirror, preseed.txt)
#   FreeBSD <ver> installer        freebsd/<ver>_amd64/{loader_pxe.efi,pxeboot} on TFTP (only the
#                                  versions listed in FREEBSD_VERSIONS)
#   OpenBSD installer              boot/ipxe/entries.d/openbsd.sh (other fragments land here too)
#   GRUB (only with PXE_IPXE_GRUB=1), iPXE shell, reboot
# Deploy with boot/deploy-menu.sh.
#
# Variables (config.local): PXE_IPXE_TITLE (default PXE_TITLE), PXE_IPXE_DEFAULT (item name,
# default the first entry = Debian diskless), PXE_IPXE_TIMEOUT (seconds, 0 = wait forever, default 10),
# PXE_IPXE_DEBIAN_SUITES (default DEBIAN_LOCAL_SUITES = "bookworm trixie"),
# PXE_IPXE_CONSOLE_ARGS (default "console=tty0 console=ttyS0,115200n8"; "" = none),
# PXE_IPXE_INSTALLER_CONSOLE_ARGS (installers, default = PXE_IPXE_CONSOLE_ARGS),
# PXE_IPXE_GRUB (1 adds the legacy GRUB fallback entry, default 0: single-layer menu), PXE_IPXE_ENTRIES_DIR (extra fragment dir), PXE_DISKLESS_DEBIAN[_DIR|_ARGS|_TITLE], PXE_IMAGES_URL.

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

	# Kernel console arguments, identical for installers and diskless: screen and serial
	# (ttyS0 = what a VM/server serial console attaches to). The last console= is /dev/console,
	# so serial is last. Verified in QEMU: debian-installer then shows its dialogs on the serial
	# port only (it uses the serial console whenever one is given, in either order) and the
	# screen stops at the kernel log. Machines without serial console set per machine
	# (ipxe/mac-aa-bb-cc-dd-ee-ff.ipxe) installer_console / diskless_console (e.g. "console=tty0"),
	# which replaces the default; ${installer_args} / ${diskless_args} are appended after it.
	# "" in config.local removes the arguments.
	local console_args="${PXE_IPXE_CONSOLE_ARGS-console=tty0 console=ttyS0,115200n8}"
	local inst_console_args="${PXE_IPXE_INSTALLER_CONSOLE_ARGS-${console_args}}"

	# Entries are collected per group and assembled in a fixed order at the end (diskless images
	# first, then installers, then the rest); keys 1..9 follow that final order.
	#   add_gap TITLE                    non-selectable heading in the current group
	#   add_item NAME LABEL [KEY]        body lines follow on stdin, appended after ":NAME"
	# ${cur_grp} is the current group: diskless | debian | freebsd | extra | other
	local -a e_grp=() e_line=() e_name=() e_key=() e_blk=()
	local cur_grp=diskless n=0 key
	add_gap() { e_grp+=("${cur_grp}"); e_line+=("item --gap -- $1"); e_name+=(""); e_key+=(""); e_blk+=(""); }
	add_item() {
		e_grp+=("${cur_grp}"); e_line+=("$2"); e_name+=("$1"); e_key+=("${3:-}")
		e_blk+=(":$1"$'\n'"$(cat)")
	}

	# --- Debian installers -------------------------------------------------------------
	cur_grp=debian
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
				kernel ${kernel_url} url=${preseed} \${installer_console} \${installer_args} || goto failed
				initrd ${initrd_url} || goto failed
				boot || goto failed
				goto failed
			EOF
			if [[ -n "${fw_url}" ]]; then
				add_item "deb-${codename}-fw" "${label} installer +firmware" <<-EOF
					imgfree
					kernel ${kernel_url} url=${preseed} \${installer_console} \${installer_args} || goto failed
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
	local console_defaults=""
	[[ -z "${inst_console_args}" ]] || console_defaults+='isset ${installer_console} || set installer_console '"${inst_console_args}"$'\n'
	[[ -z "${console_args}" || "${dl_args}" == *console=* ]] || console_defaults+='isset ${diskless_console} || set diskless_console '"${console_args}"$'\n'
	cur_grp=diskless
	local dl_gap=0
	if [[ "${dl_enabled}" == 1 ]]; then
		add_gap "Diskless"; dl_gap=1
		# ${diskless_args}: optional extra kernel arguments (e.g. console=ttyS0,115200n8) set
		# by the per-machine script ipxe/mac-<mac>.ipxe
		add_item diskless-debian "${dl_title}" <<-EOF
			imgfree
			kernel ${dl_url}/vmlinuz ${dl_args} \${diskless_console} \${diskless_args} || goto failed
			initrd ${dl_url}/initrd.img || goto failed
			boot || goto failed
			goto failed
		EOF
	fi

	# --- FreeBSD (patched loaders on TFTP, staged by build-tftp-stage.sh) -----------------
	cur_grp=freebsd
	local folder fb_gap=0 ver
	while read -r folder; do
		ver="${folder%%_*}"
		((fb_gap)) || { add_gap "FreeBSD"; fb_gap=1; }
		add_item "freebsd-${ver}" "FreeBSD ${ver} installer (NFS root)" <<-EOF
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
	cur_grp=extra
	for frag in "${PXE_IPXE_ENTRIES_DIR:-}"/*.sh "$(dirname -- "${BASH_SOURCE[0]}")"/ipxe/entries.d/*.sh; do
		[[ -f "${frag}" ]] || continue
		# shellcheck source=/dev/null
		source "${frag}"
		cur_grp=extra
	done

	# --- Fallbacks / tools ---------------------------------------------------------------
	cur_grp=other
	add_gap "Other"
	if [[ "${PXE_IPXE_GRUB:-0}" == 1 ]]; then
		add_item grub "Legacy GRUB menu (fallback)" g <<-EOF
			iseq \${platform} efi || goto grub-bios
			imgfetch --name grub.efi tftp://\${srv}/grub/x86_64-efi/grubnetx64-ipxe.efi || goto failed
			ifclose
			imgexec grub.efi || goto failed
			goto failed
			:grub-bios
			chain --name core.pxe tftp://\${srv}/grub/i386-pc/core-ipxe.0 || goto failed
			goto failed
		EOF
	fi
	add_item shell "iPXE shell" s <<-EOF
		shell
		goto start
	EOF
	add_item reboot "Reboot" r <<-EOF
		reboot
	EOF

	local -a items=() blocks=()
	local g i
	for g in diskless debian freebsd extra other; do
		for i in "${!e_grp[@]}"; do
			[[ "${e_grp[i]}" == "${g}" ]] || continue
			if [[ -z "${e_name[i]}" ]]; then
				items+=("${e_line[i]}")
				continue
			fi
			if [[ -n "${e_key[i]}" ]]; then
				key="--key ${e_key[i]} "
			else
				n=$((n + 1))
				if ((n <= 9)); then key="--key ${n} "; else key=""; fi
			fi
			items+=("item ${key}${e_name[i]} ${e_line[i]}")
			blocks+=("${e_blk[i]}")
			[[ -z "${default_item}" ]] && default_item="${e_name[i]}"
		done
	done

	# BIOS clients whose NIC ROM is iPXE (QEMU/libvirt, some servers) arrive here with the old iPXE
	# of the ROM: no serial console, and OpenBSD pxeboot cannot run on top of undionly there. They
	# load the native-driver ipxe.pxe (iPXE 2.x, built by boot/ipxe/build.sh) once; its embedded script
	# sets ${ipxe20} before chaining this script again. PXE_IPXE_UPGRADE=auto|1|0 (auto: ipxe.pxe exists).
	local upgrade_block="" upgrade="${PXE_IPXE_UPGRADE:-auto}" ipxe_dir
	ipxe_dir="${PXE_IPXE_DIR:-${PXE_DOWNLOADS:-$(dirname -- "${PXE_LOCAL_ROOT}")/downloads}/ipxe}"
	if [[ "${upgrade}" == auto ]]; then [[ -s "${ipxe_dir}/ipxe.pxe" ]] && upgrade=1 || upgrade=0; fi
	if [[ "${upgrade}" == 1 ]]; then
		upgrade_block='isset ${ipxe20} && goto ready || goto upgrade-check
:upgrade-check
iseq ${platform} pcbios || goto ready
echo Old iPXE from the NIC ROM, loading iPXE 2.x
chain --name ipxe.pxe tftp://${srv}/ipxe/ipxe.pxe || set ipxe20 failed
:ready'
	fi

	{
		cat <<-EOF
			#!ipxe
			# Generated by boot/gen-boot-ipxe.sh (./simple-pxe ipxe-menu); do not edit.
			# Needs iPXE >= 1.21 (UEFI initrd support); built by boot/ipxe/build.sh.
			:start
			isset \${srv} || set srv \${next-server}
			isset \${srv} || set srv ${http_host}
		EOF
		[[ -z "${upgrade_block}" ]] || printf '%s\n' "${upgrade_block}"
		cat <<-EOF
			# Optional per-machine settings: ipxe/mac-aa-bb-cc-dd-ee-ff.ipxe (e.g. set installer_console console=tty0, set diskless_args ...)
			isset \${mac} && chain tftp://\${srv}/ipxe/mac-\${mac:hexhyp}.ipxe || goto menu
			:menu
			${console_defaults}menu ${title}
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
