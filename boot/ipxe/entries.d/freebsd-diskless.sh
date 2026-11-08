#!/bin/bash
# Example fragment (not active: the name does not end in .sh). Adds a FreeBSD 15.1 diskless
# entry that is only listed when the image exists. Paths and loader are placeholders:
# adapt them to what the diskless build publishes.
fbd_dir="${PXE_IMAGES_ROOT:-/srv/pxe-images}/freebsd-15.1-diskless/current"
if [[ -s "${fbd_dir}/loader_pxe.efi" && -s "${fbd_dir}/pxeboot" ]]; then
	add_item freebsd-diskless "FreeBSD 15.1 diskless (RAM/NFS root)" <<-EOF
		iseq \${platform} efi || goto freebsd-diskless-bios
		chain tftp://\${srv}/freebsd/15.1_amd64-diskless/loader_pxe.efi || goto failed
		goto failed
		:freebsd-diskless-bios
		chain --name pxeboot.pxe tftp://\${srv}/freebsd/15.1_amd64-diskless/pxeboot || goto failed
		goto failed
	EOF
fi
