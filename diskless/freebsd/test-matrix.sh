#!/bin/bash
# Boot the diskless tree in QEMU for BIOS/UEFI x NIC models, wait for the serial login
# prompt, run verify-guest.sh. Needs `qemu-test.sh setup` first.
#   diskless/freebsd/test-matrix.sh [mode:nic ...]     (default: all six)
#   IPXE=1 ...                                         chain through iPXE (qemu-test.sh -i)
set -uo pipefail
HERE="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cases=("$@")
[[ ${#cases[@]} -gt 0 ]] || cases=(uefi:virtio-net-pci uefi:e1000 uefi:rtl8139 bios:virtio-net-pci bios:e1000 bios:rtl8139)
mkdir -p /tmp/fbsd-matrix
for c in "${cases[@]}"; do
	mode="${c%%:*}" nic="${c##*:}"
	out="/tmp/fbsd-diskless-${mode}-${nic}"
	res="/tmp/fbsd-matrix/${mode}-${nic}${IPXE:+-ipxe}.log"
	"${HERE}/qemu-test.sh" stop
	setsid "${HERE}/qemu-test.sh" run "${mode}" -n "${nic}" -d 20 -k ${IPXE:+-i} >"${res}.run" 2>&1 </dev/null
	login=no
	for ((i = 0; i < 40; i++)); do
		if grep -qa "login: " "${out}/serial.log" 2>/dev/null; then login=yes; break; fi
		sleep 5
	done
	ip="$(awk '{print $3}' "${out}/leases" 2>/dev/null | head -1)"
	{
		echo "case ${mode} ${nic}: serial login prompt: ${login}, ip ${ip:-none}"
		if [[ "${login}" == yes && -n "${ip}" ]]; then
			sleep 3
			"${HERE}/verify-guest.sh" "${ip}" "fbtest-${nic%%-*}"
		fi
		sleep 1
	} >"${res}" 2>&1
	grep -c '^PASS' "${res}" | sed "s/^/${mode} ${nic}: PASS=/"
	grep '^FAIL' "${res}" | sed "s/^/${mode} ${nic}: /"
	mon() { echo "$1" | socat - "unix-connect:${out}/mon" >/dev/null 2>&1 || true; }
	mon "screendump ${out}/final.ppm"; sleep 1; convert "${out}/final.ppm" "${out}/final.png" 2>/dev/null && rm -f "${out}/final.ppm"
	"${HERE}/qemu-test.sh" stop
	sleep 2
done
