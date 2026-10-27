#!/bin/bash
#menu: FreeBSD
#root: freebsd

source functions.sh
cd "${LOCAL_PATH}" || exit 1

# FreeBSD cannot be started from GRUB when GRUB itself was network booted:
#  - BIOS:  kfreebsd + mfs_root resets the machine, and GRUB cannot chain pxeboot
#           (it needs the PXE stack in the state the firmware left it).
#  - UEFI:  GRUB keeps the NIC open exclusively, so loader.efi fails with
#           "can't open network interface for exclusive access".
# FreeBSD is therefore booted straight from the firmware / iPXE with the patched
# loaders that prepare.d/freebsd.sh builds (boot/pxeboot_nfs for BIOS,
# boot/loader_pxe.efi for UEFI), see boot/README.md. This menu only lists what is
# available and how to reach it.

versions=()
while read -r folder; do
	[[ -s "${PXE_LOCAL_ROOT}/freebsd/${folder}/cd.iso" ]] || continue
	versions+=("${folder%%_*}")
done < <(freebsd_published_folders)

(( ${#versions[@]} > 0 )) || exit 0

cat <<- EOF
	menuentry 'FreeBSD ${versions[*]} (not bootable from GRUB; use the main iPXE menu)' {
	  echo "FreeBSD cannot be chain-loaded from GRUB."
	  echo "Reboot and choose FreeBSD in the iPXE menu, or ask the PXE admin to"
	  echo "point this machine's DHCP filename at the FreeBSD loader."
	  echo "Press any key to reboot..."
	  read
	  reboot
	}
EOF

# vim: set ts=4 sw=4 sts=4 noexpandtab nosta:
