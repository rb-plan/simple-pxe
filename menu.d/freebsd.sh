#!/bin/bash
#menu: FreeBSD
#root: freebsd

source functions.sh
cd "${LOCAL_PATH}" || exit 1

# Only list trees that prepare completed (hidden .tmp.*/.old.* dirs and empty or
# partial trees are skipped).
while read -r folder; do
	[[ -s "${folder}/cd.iso" && -s "${folder}/boot/loader_pxe.efi" \
		&& -s "${folder}/boot/kernel/kernel" ]] || continue
	IFS='_' read -r version arch <<< "${folder}"
	[[ ${arch} == "i386" ]] && grub_cpu=i386 || grub_cpu=x86_64

	cat <<- EOF
		if [ \$grub_platform != efi -o \$grub_cpu = ${grub_cpu} ]; then
		  menuentry 'FreeBSD ${version}-RELEASE (${arch})' {
		    if [ \$grub_platform = efi ]; then
		      chainloader ${GRUB_PATH}/${folder}/boot/loader_pxe.efi
		    else
		      echo "Loading kernel..."
		      kfreebsd ${GRUB_PATH}/${folder}/boot/kernel/kernel
		      kfreebsd_loadenv ${GRUB_PATH}/${folder}/boot/device.hints
		      echo "Loading rootfs image..."
		      kfreebsd_module ${GRUB_PATH}/${folder}/cd.iso type=mfs_root
		      set kFreeBSD.vfs.root.mountfrom="cd9660:/dev/md0"
		      set kFreeBSD.vfs.root.mountfrom.options=ro
		    fi
		  }
		fi
	EOF
done < <(find . -mindepth 1 -maxdepth 1 -type d -name '[0-9]*_*' -printf '%f\n' | sort -t_ -k1,1Vr -k2,2)

# vim: set ts=4 sw=4 sts=4 noexpandtab nosta:
