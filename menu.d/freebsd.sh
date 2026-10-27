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
	[[ -s "${folder}/cd.iso" && -s "${folder}/boot/loader_pxe.efi" \
		&& -s "${folder}/boot/pxeboot_nfs" && -s "${folder}/boot/kernel/kernel" ]] || continue
	IFS='_' read -r version arch <<< "${folder}"
	[[ ${arch} == "i386" ]] && continue
	versions+=("${version}")
done < <(find . -mindepth 1 -maxdepth 1 -type d -name '[0-9]*_*' -printf '%f\n' | sort -t_ -k1,1Vr -k2,2)

(( ${#versions[@]} > 0 )) || exit 0

cat <<- EOF
	menuentry 'FreeBSD ${versions[*]} (not bootable from GRUB; use the iPXE menu)' {
	  echo "FreeBSD cannot be chain-loaded from GRUB."
	  echo "Reboot and choose FreeBSD in the iPXE menu, or ask the PXE admin to"
	  echo "point this machine's DHCP filename at the FreeBSD loader."
	  echo "Press any key to reboot..."
	  read
	  reboot
	}
EOF

# vim: set ts=4 sw=4 sts=4 noexpandtab nosta:
