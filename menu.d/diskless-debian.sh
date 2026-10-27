#!/bin/bash
#menu: Debian diskless
#root: diskless-debian

source functions.sh

# Diskless Debian (live-boot): kernel + initrd come from the image server over HTTP, the
# initramfs then downloads filesystem.squashfs itself (fetch=) and runs from RAM.
# Built by diskless/debian/build.sh, served from /images/ (boot/nginx/images-location.conf).
# The iPXE menu (boot/build-tftp-stage.sh) is the better path (GRUB is slow with big files);
# this entry is for machines that only reach GRUB.
#
# Variables (config.local):
#   PXE_DISKLESS_DEBIAN=auto|1|0   auto: only when ${PXE_IMAGES_ROOT}/<dir>/current/vmlinuz exists
#   PXE_IMAGES_ROOT                where the images live on this host (default /srv/pxe-images)
#   PXE_IMAGES_URL                 public URL of PXE_IMAGES_ROOT (default http://<PXE_HTTP_ROOT host>/images)
#   PXE_DISKLESS_DEBIAN_DIR        build dir below it (default debian-trixie-diskless)
#   PXE_DISKLESS_DEBIAN_ARGS       kernel command line (default: boot=live fetch=<url>/filesystem.squashfs ip=dhcp)

host="$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"${PXE_HTTP_ROOT}")"
images_root="${PXE_IMAGES_ROOT:-/srv/pxe-images}"
dir="${PXE_DISKLESS_DEBIAN_DIR:-debian-trixie-diskless}"
url="${PXE_IMAGES_URL:-http://${host}/images}/${dir}/current"
args="${PXE_DISKLESS_DEBIAN_ARGS:-boot=live fetch=${url}/filesystem.squashfs ip=dhcp}"
enabled="${PXE_DISKLESS_DEBIAN:-auto}"
if [[ "${enabled}" == auto ]]; then
	[[ -s "${images_root}/${dir}/current/vmlinuz" ]] && enabled=1 || enabled=0
fi

if [[ "${enabled}" != 1 ]]; then
	cat <<- EOF
		menuentry 'Debian diskless: no image built (see diskless/debian/README.md)' {
		  true
		}
	EOF
	exit 0
fi

grub_linux_entry \
	"Debian trixie diskless (RAM, ssh key login)" \
	"$(url2grub "${url}/vmlinuz")" \
	"$(url2grub "${url}/initrd.img")" \
	"${args}"

# vim: set ts=4 sw=4 sts=4 noexpandtab nosta:
