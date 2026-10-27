#!/bin/bash
# Stage the OpenBSD network boot files into the TFTP stage (called by build-tftp-stage.sh):
#
#   openbsd/pxeboot         BIOS loader (OpenBSD PXE boot, chain-loaded by iPXE)
#   openbsd/BOOTX64.EFI     UEFI loader (efiboot)
#   openbsd/bsd.rd          installer kernel + ramdisk
#   bsd.rd                  same file at the TFTP root (for "boot tftp:/bsd.rd" typed by hand)
#   etc/boot.conf           read by both loaders from the TFTP *root* (absolute /etc/boot.conf)
#   etc/random.seed         512 random bytes (the loaders complain without it)
#
# Nothing is staged (and no error) when prepare.d/openbsd.sh has not published the files.
set -euo pipefail
STAGE="${1:?stage dir}"
cd "$(dirname -- "$0")/../.."
source config.local
source boot/lib.sh
openbsd_published || { echo "OpenBSD: not published under ${PXE_LOCAL_ROOT}/openbsd, skipped (run ./simple-pxe prepare)" >&2; exit 0; }

src="${PXE_LOCAL_ROOT}/openbsd/${OPENBSD_VERSION}/amd64"
mkdir -p "${STAGE}/openbsd" "${STAGE}/etc"
cp "${src}/pxeboot" "${src}/BOOTX64.EFI" "${src}/bsd.rd" "${STAGE}/openbsd/"
# also at the TFTP root: tftp: paths typed at the boot> prompt are relative to the root, not to openbsd/
cp "${src}/bsd.rd" "${STAGE}/bsd.rd"
boot/openbsd/boot.conf.sh >"${STAGE}/etc/boot.conf"
head -c 512 /dev/urandom >"${STAGE}/etc/random.seed"
echo "OpenBSD ${OPENBSD_VERSION}: staged openbsd/{pxeboot,BOOTX64.EFI,bsd.rd}, etc/{boot.conf,random.seed}" >&2
