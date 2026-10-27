#!/bin/bash
# Build the first-stage network boot files (GRUB + iPXE, BIOS + UEFI) into a staging
# directory that is NOT served over HTTP. Copy the result to the TFTP root.
#
#   ./boot/build-tftp-stage.sh [stage-dir]
#
# Needs: grub-common, grub-pc-bin (i386-pc), grub-efi-amd64-bin (x86_64-efi).
# Optional: PXE_BOOT_HTTP_HOST overrides the host used in (http,<host>);
#           PXE_BOOT_TFTP_HOST is the TFTP host baked into the iPXE-chained GRUB images
#           (default: the HTTP host);
#           PXE_DEBIAN_NETBOOT_TARBALL adds Debian's own installer as a fallback;
#           PXE_IPXE_DIR is where undionly.kpxe and snponly.efi come from
#           (default: ${PXE_DOWNLOADS}/ipxe, then /usr/lib/ipxe);
#           PXE_IPXE_TITLE is the title of the iPXE menu.

set -euo pipefail

cd "$(dirname -- "$0")/.."
source config.local

STAGE="${1:-${PXE_TFTP_STAGE:-${PXE_LOCAL_ROOT}/tftp-stage}}"
HTTP_HOST="${PXE_BOOT_HTTP_HOST:-$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"${PXE_HTTP_ROOT}")}"
TFTP_HOST="${PXE_BOOT_TFTP_HOST:-${HTTP_HOST}}"
HTTP_PATH="$(sed -E 's#^[a-z]+://[^/]+##' <<<"${PXE_HTTP_ROOT}")"
DOWNLOADS="${PXE_DOWNLOADS:-$(dirname -- "${PXE_LOCAL_ROOT}")/downloads}"
NETBOOT_TARBALL="${PXE_DEBIAN_NETBOOT_TARBALL:-${DOWNLOADS}/debian/stable/netboot.tar.gz}"
IPXE_TITLE="${PXE_IPXE_TITLE:-PXE boot}"

# Embedded into all images so the menus work even if TFTP module loading fails.
COMMON_MODULES="normal configfile http tftp net echo test true sleep read cat ls regexp \
search search_fs_file search_fs_uuid search_label linux chain boot bsd gzio xzio \
part_gpt part_msdos fat iso9660 loopback reboot halt help minicmd eval loadenv gettext \
all_video video video_fb font png terminal gfxterm progress multiboot multiboot2"
PC_MODULES="pxe vbe vga video_bochs video_cirrus"
EFI_MODULES="efinet efi_gop efi_uga lsefi linuxefi"

[[ "${STAGE}" == /*/* && "$(basename -- "${STAGE}")" == tftp-stage* ]] \
	|| { echo "refusing to wipe unexpected stage dir: ${STAGE}" >&2; exit 1; }
rm -rf "${STAGE}"
mkdir -p "${STAGE}/grub/i386-pc" "${STAGE}/grub/x86_64-efi" "${STAGE}/grub/grub.cfg.d"

# -p /grub: config and modules are looked up on the device GRUB was loaded from
# (the TFTP server), exactly what grub-mknetdir does.
grub-mkimage -O i386-pc-pxe -p /grub \
	-o "${STAGE}/grub/i386-pc/core.0" ${COMMON_MODULES} ${PC_MODULES}
grub-mkimage -O x86_64-efi -p /grub \
	-o "${STAGE}/grub/x86_64-efi/grubnetx64.efi" ${COMMON_MODULES} ${EFI_MODULES}

# Variants for GRUB started by iPXE (ipxe/boot.ipxe). When iPXE chain-loads GRUB there is
# no TFTP boot device GRUB could derive its prefix from, and the DHCP server's siaddr
# (what GRUB's net_default_server may end up as) is not necessarily the TFTP host. So the
# TFTP host is baked in twice: -p sets the image prefix and the embedded script sets
# prefix/root again.
# The -c script runs in rescue mode: plain commands only (no if/for), and a failing
# command does not stop it. GRUB usually inherits the NIC configuration from the PXE
# base code protocol that iPXE installs, so first try "normal" straight away (it only
# returns when grub.cfg cannot be read); only then fall back to GRUB's own DHCP
# (net_bootp, which can stall for a long time on a NIC without a DHCP server).
# The echo lines make a stall on real hardware diagnosable.
EMBED="$(mktemp)"
trap 'rm -f "${EMBED}"' EXIT
cat >"${EMBED}" <<EOF
set root=tftp,${TFTP_HOST}
set prefix=(tftp,${TFTP_HOST})/grub
echo ncosbit: GRUB started by iPXE, loading (tftp,${TFTP_HOST})/grub/grub.cfg
normal (tftp,${TFTP_HOST})/grub/grub.cfg
echo ncosbit: no network configuration inherited from iPXE, running net_bootp...
net_bootp
echo ncosbit: ip=\${net_default_ip} dhcp-next-server=\${net_default_server}; retrying grub.cfg
normal (tftp,${TFTP_HOST})/grub/grub.cfg
EOF
grub-mkimage -O i386-pc-pxe -p "(tftp,${TFTP_HOST})/grub" -c "${EMBED}" \
	-o "${STAGE}/grub/i386-pc/core-ipxe.0" ${COMMON_MODULES} ${PC_MODULES}
grub-mkimage -O x86_64-efi -p "(tftp,${TFTP_HOST})/grub" -c "${EMBED}" \
	-o "${STAGE}/grub/x86_64-efi/grubnetx64-ipxe.efi" ${COMMON_MODULES} ${EFI_MODULES}

# Runtime-loadable modules (insmod) for each platform.
cp /usr/lib/grub/i386-pc/{*.mod,*.lst} "${STAGE}/grub/i386-pc/"
cp /usr/lib/grub/x86_64-efi/{*.mod,*.lst} "${STAGE}/grub/x86_64-efi/"
rm -f "${STAGE}"/grub/*/core.img "${STAGE}"/grub/*/kernel.img

cp grub.example/grub.cfg "${STAGE}/grub/grub.cfg"
# The first DNS/HTTP request from GRUB can be lost (seen with UEFI + QEMU NAT);
# "test -f" does not work on (http), so simply retry configfile.
cat >"${STAGE}/grub/grub.cfg.d/default" <<EOF
for try in 1 2 3 4 5 6; do
  configfile (http,${HTTP_HOST})${HTTP_PATH}/menu/root.menu
  sleep 1
done
EOF

# FreeBSD cannot be started from GRUB (see menu.d/freebsd.sh). Its patched loaders
# (BIOS pxeboot, UEFI loader_pxe.efi; NFS root baked in by prepare.d/freebsd.sh) are
# staged per version so DHCP or iPXE can point straight at them:
#   freebsd/<ver>_amd64/pxeboot  freebsd/<ver>_amd64/loader_pxe.efi
FREEBSD_STAGED=()
while read -r folder; do
	src="${PXE_LOCAL_ROOT}/freebsd/${folder}/boot"
	[[ -s "${src}/pxeboot_nfs" && -s "${src}/loader_pxe.efi" ]] || continue
	mkdir -p "${STAGE}/freebsd/${folder}"
	cp "${src}/pxeboot_nfs" "${STAGE}/freebsd/${folder}/pxeboot"
	cp "${src}/loader_pxe.efi" "${STAGE}/freebsd/${folder}/loader_pxe.efi"
	FREEBSD_STAGED+=("${folder}")
done < <(find "${PXE_LOCAL_ROOT}/freebsd" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*_amd64' -printf '%f\n' 2>/dev/null | sort -t_ -k1,1Vr)

# iPXE first stage: BIOS undionly.kpxe, UEFI snponly.efi. boot.ipxe is a small menu
# that chains GRUB (Linux and others) or one of the FreeBSD loaders.
IPXE_DIR=""
for d in "${PXE_IPXE_DIR:-}" "${DOWNLOADS}/ipxe" /usr/lib/ipxe; do
	if [[ -n "${d}" && -s "${d}/undionly.kpxe" && -s "${d}/snponly.efi" ]]; then
		IPXE_DIR="${d}"
		break
	fi
done
if [[ -n "${IPXE_DIR}" ]]; then
	mkdir -p "${STAGE}/ipxe"
	cp "${IPXE_DIR}/undionly.kpxe" "${IPXE_DIR}/snponly.efi" "${STAGE}/ipxe/"
	{
		echo '#!ipxe'
		echo '# Generated by boot/build-tftp-stage.sh; do not edit.'
		echo 'set srv ${next-server}'
		echo '# Optional per-machine script: ipxe/mac-aa-bb-cc-dd-ee-ff.ipxe'
		echo 'isset ${mac} && chain tftp://${srv}/ipxe/mac-${mac:hexhyp}.ipxe || echo No per-MAC script'
		echo "menu ${IPXE_TITLE} (\${platform})"
		echo 'item --key g grub GRUB menu (Debian and others)'
		n=0
		for folder in "${FREEBSD_STAGED[@]}"; do
			n=$((n + 1))
			echo "item --key ${n} fbsd${n} FreeBSD ${folder%%_*}-RELEASE ${folder#*_} (diskless NFS root)"
		done
		echo 'item --key s shell iPXE shell'
		echo 'choose --default grub --timeout 10000 target || goto grub'
		echo 'goto ${target}'
		echo ':grub'
		echo 'iseq ${platform} efi && chain tftp://${srv}/grub/x86_64-efi/grubnetx64-ipxe.efi || chain --name core.pxe tftp://${srv}/grub/i386-pc/core-ipxe.0'
		echo 'goto shell'
		n=0
		for folder in "${FREEBSD_STAGED[@]}"; do
			n=$((n + 1))
			echo ":fbsd${n}"
			echo "set fb ${folder}"
			echo 'goto fbsd'
		done
		echo ':fbsd'
		echo 'iseq ${platform} efi && chain tftp://${srv}/freebsd/${fb}/loader_pxe.efi || chain --name pxeboot.pxe tftp://${srv}/freebsd/${fb}/pxeboot'
		echo ':shell'
		echo 'shell'
	} >"${STAGE}/ipxe/boot.ipxe"
else
	echo "WARNING: iPXE binaries not found (set PXE_IPXE_DIR); no iPXE stage in ${STAGE}" >&2
fi

if [[ -f "${NETBOOT_TARBALL}" ]]; then
	# Fallback: Debian's own PXE tree (BIOS pxelinux.0, UEFI signed bootnetx64.efi).
	tar -C "${STAGE}" -xzf "${NETBOOT_TARBALL}"
fi

chmod -R a+rX "${STAGE}"
grub-script-check "${STAGE}/grub/grub.cfg"
grub-script-check "${STAGE}/grub/grub.cfg.d/default"

echo "Staged in ${STAGE}:"
(cd "${STAGE}" && find . -type f \( -name 'core.0' -o -name 'core-ipxe.0' -o -name 'grubnetx64.efi' -o -name 'grubnetx64-ipxe.efi' \
	-o -name grub.cfg -o -name default -o -name undionly.kpxe -o -name snponly.efi -o -name boot.ipxe \
	-o -name pxeboot -o -name loader_pxe.efi -o -name pxelinux.0 -o -name bootnetx64.efi -o -name grubx64.efi \) \
	-printf '%10s  %p\n' | sort -k2)
