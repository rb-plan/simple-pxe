#!/bin/bash
# OpenBSD installer entry (listed once prepare.d/openbsd.sh has published the files and
# boot/openbsd/stage-tftp.sh has staged them on TFTP). Sourced by boot/gen-boot-ipxe.sh.
# The loaders (BIOS pxeboot, UEFI BOOTX64.EFI) read /etc/boot.conf from the TFTP root, which
# boots openbsd/bsd.rd; the sets come from ${PXE_HTTP_ROOT}/openbsd/<ver>/amd64 (HTTP install).
if openbsd_published; then
	add_gap "OpenBSD"
	# UEFI: efiboot only sets up its network device when the firmware itself PXE-loaded it
	# (verified in QEMU/OVMF and on real hardware: chain-loaded from iPXE it prints
	# "cannot open tftp:/etc/random.seed" and falls back to /bsd). So on UEFI the menu entry only
	# explains; use the DHCP boot file openbsd/BOOTX64.EFI for that machine (boot/README.md).
	add_item "openbsd-${OPENBSD_VERSION}" "OpenBSD ${OPENBSD_VERSION} installer (${OPENBSD_CONSOLE} console; UEFI: DHCP boot file)" <<-EOF
		iseq \${platform} efi || goto openbsd-${OPENBSD_VERSION}-bios
		echo OpenBSD efiboot cannot be started from iPXE (it needs the firmware network device).
		echo Give this machine the DHCP boot file openbsd/BOOTX64.EFI and netboot it directly
		echo (vmsrt: boot/openbsd/dhcp-obsd-toggle.sh on, and back with: off).
		prompt Press any key to return to the menu
		goto start
		:openbsd-${OPENBSD_VERSION}-bios
		chain --name pxeboot.pxe tftp://\${srv}/openbsd/pxeboot || goto failed
		goto failed
	EOF
fi
