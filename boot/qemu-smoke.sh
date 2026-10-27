#!/bin/bash
# Boot the staged first-stage files in QEMU (user-mode net, built-in TFTP).
#
#   ./boot/qemu-smoke.sh bios|uefi [stage-dir] [seconds]
#
# GRUB output is redirected to the serial port (test copy only; the staged files
# are not modified) and the log is searched for the menu from root.menu, which
# proves TFTP (stage 1) and HTTP (menu) both work. No physical network is used
# except the guest reaching the HTTP host through QEMU NAT.

set -euo pipefail

cd "$(dirname -- "$0")/.."
source config.local

MODE="${1:?usage: $0 bios|uefi [stage-dir] [seconds]}"
STAGE="${2:-${PXE_TFTP_STAGE:-${PXE_LOCAL_ROOT}/tftp-stage}}"
SECS="${3:-45}"
WORK="$(mktemp -d /tmp/pxe-smoke.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

cp -a "${STAGE}/grub" "${WORK}/grub"
{
	echo 'serial --unit=0 --speed=115200'
	echo 'terminal_input serial'
	echo 'terminal_output serial'
	cat "${STAGE}/grub/grub.cfg"
} >"${WORK}/grub/grub.cfg"

LOG="${WORK}/serial.log"
COMMON=(-m 1024 -nographic -display none -serial "file:${LOG}" -monitor none
	-device e1000,netdev=n0 -boot n)
[[ -w /dev/kvm ]] && COMMON+=(-enable-kvm -cpu host)

case "${MODE}" in
bios)
	timeout "${SECS}" qemu-system-x86_64 "${COMMON[@]}" \
		-netdev "user,id=n0,tftp=${WORK},bootfile=grub/i386-pc/core.0" || true
	;;
uefi)
	cp /usr/share/OVMF/OVMF_VARS_4M.fd "${WORK}/vars.fd"
	timeout "${SECS}" qemu-system-x86_64 -machine q35 "${COMMON[@]}" \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
		-drive if=pflash,format=raw,file="${WORK}/vars.fd" \
		-netdev "user,id=n0,tftp=${WORK},bootfile=grub/x86_64-efi/grubnetx64.efi" || true
	;;
*) echo "mode must be bios or uefi" >&2; exit 2 ;;
esac

tr -d '\033' <"${LOG}" | sed -E 's/\[[0-9;?]*[A-Za-z]//g' | tr -s '\r' '\n' >"${LOG}.txt" || true
cp "${LOG}.txt" "/tmp/pxe-smoke-${MODE}.log"
echo "--- serial log: /tmp/pxe-smoke-${MODE}.log"
if grep -q 'Distros' "${LOG}.txt"; then
	echo "PASS ${MODE}: GRUB loaded over TFTP and rendered root.menu fetched over HTTP"
else
	echo "FAIL ${MODE}: menu not seen" >&2
	tail -n 20 "${LOG}.txt" >&2
	exit 1
fi
