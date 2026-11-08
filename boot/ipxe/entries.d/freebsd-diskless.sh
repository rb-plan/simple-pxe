#!/bin/bash
# FreeBSD 15.1 diskless (NFS root) entry, in the FreeBSD group right after the installer.
# The patched loaders are published by diskless/freebsd/build.sh in ${PXE_IMAGES_ROOT}/tftp
# and overlaid onto the TFTP stage by boot/build-tftp-stage.sh (freebsd/15.1_diskless/).
# The entry is only listed when both loaders exist (PXE_FREEBSD_DISKLESS=0 hides it, 1 forces it).
# No console arguments: the loader takes its consoles (serial + video) from /boot/loader.conf
# on the NFS root.
fbd_dir="${PXE_IMAGES_ROOT:-/srv/pxe-images}/tftp/freebsd/15.1_diskless"
fbd_enabled="${PXE_FREEBSD_DISKLESS:-auto}"
if [[ "${fbd_enabled}" == auto ]]; then
	[[ -s "${fbd_dir}/loader_pxe.efi" && -s "${fbd_dir}/pxeboot" ]] && fbd_enabled=1 || fbd_enabled=0
fi
if [[ "${fbd_enabled}" == 1 ]]; then
	((fb_gap)) || { add_gap "FreeBSD"; fb_gap=1; }
	add_item freebsd-15.1-diskless "FreeBSD 15.1 diskless (NFS root, ssh key login)" <<-EOF
		iseq \${platform} efi || goto freebsd-15.1-diskless-bios
		chain tftp://\${srv}/freebsd/15.1_diskless/loader_pxe.efi || goto failed
		goto failed
		:freebsd-15.1-diskless-bios
		chain --name pxeboot.pxe tftp://\${srv}/freebsd/15.1_diskless/pxeboot || goto failed
		goto failed
	EOF
fi
