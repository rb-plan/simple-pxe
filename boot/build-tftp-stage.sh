#!/bin/bash
# Build the first-stage network boot files (GRUB for BIOS + UEFI) into a staging
# directory that is NOT served over HTTP. Copy the result to the TFTP root.
#
#   ./boot/build-tftp-stage.sh [stage-dir]
#
# Needs: grub-common, grub-pc-bin (i386-pc), grub-efi-amd64-bin (x86_64-efi).
# Optional: PXE_BOOT_HTTP_HOST overrides the host used in (http,<host>);
#           PXE_DEBIAN_NETBOOT_TARBALL adds Debian's own installer as a fallback.

set -euo pipefail

cd "$(dirname -- "$0")/.."
source config.local

STAGE="${1:-${PXE_TFTP_STAGE:-${PXE_LOCAL_ROOT}/tftp-stage}}"
HTTP_HOST="${PXE_BOOT_HTTP_HOST:-$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"${PXE_HTTP_ROOT}")}"
HTTP_PATH="$(sed -E 's#^[a-z]+://[^/]+##' <<<"${PXE_HTTP_ROOT}")"
NETBOOT_TARBALL="${PXE_DEBIAN_NETBOOT_TARBALL:-${PXE_DOWNLOADS:-$(dirname -- "${PXE_LOCAL_ROOT}")/downloads}/debian/stable/netboot.tar.gz}"

# Embedded into both images so the menus work even if TFTP module loading fails.
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

if [[ -f "${NETBOOT_TARBALL}" ]]; then
	# Fallback: Debian's own PXE tree (BIOS pxelinux.0, UEFI signed bootnetx64.efi).
	tar -C "${STAGE}" -xzf "${NETBOOT_TARBALL}"
fi

chmod -R a+rX "${STAGE}"
grub-script-check "${STAGE}/grub/grub.cfg"
grub-script-check "${STAGE}/grub/grub.cfg.d/default"

echo "Staged in ${STAGE}:"
(cd "${STAGE}" && find . -type f \( -name 'core.0' -o -name 'grubnetx64.efi' -o -name 'grub.cfg' -o -name default \
	-o -name pxelinux.0 -o -name bootnetx64.efi -o -name grubx64.efi \) -printf '%10s  %p\n' | sort -k2)
