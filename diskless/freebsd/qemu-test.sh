#!/bin/bash
# Boot the diskless FreeBSD tree in QEMU on a private tap (own subnet, own dnsmasq, own
# NFS test export) so it does not interfere with other PXE tests or the production network.
#
#   diskless/freebsd/qemu-test.sh setup               # tap fbtest0 10.98.0.1/24 + export for 10.98.0.0/24
#   diskless/freebsd/qemu-test.sh run bios|uefi [options]
#   diskless/freebsd/qemu-test.sh stop                # kill guests left running by -k
#   diskless/freebsd/qemu-test.sh teardown
#
# Options for run:
#   -n MODEL    NIC model: virtio-net-pci (default), e1000, rtl8139
#   -m MAC      client MAC (default 52:54:00:fb:15:01)
#   -r MB       RAM (default 2048)
#   -d SECS     run time (default 150); screenshots every 10 s, serial console in <out>/serial.log
#   -o DIR      output directory (default /tmp/fbsd-diskless-<mode>-<model>)
#   -i          chain through iPXE like the boot menu does: DHCP gives ipxe/{undionly.kpxe,snponly.efi},
#               iPXE then runs a throwaway script built from ipxe-menu-fragment.txt
#               (freebsd/15.1_diskless/test.ipxe, removed again after the run)
#   -k          keep the guest running after the run (it is killed otherwise)
#
# The client gets the DHCP host name fbtest-<model>, boots the patched loader directly via
# the DHCP filename (BIOS: pxeboot, UEFI: loader_pxe.efi from freebsd/15.1_diskless/), the
# loader reads kernel and /boot/loader.conf over NFS from 10.20.0.26 (route via the tap).

set -euo pipefail

HUB="${PXE_TEST_HUB_IP:-10.20.0.26}"
TAP=fbtest0
NET=10.98.0.0/24
GW=10.98.0.1
EXPORT_FILE=/etc/exports.d/freebsd-diskless-qemutest.exports
ROOT="${ROOT:-/srv/pxe-images/freebsd-15.1-diskless}"
SUB="${TFTP_SUBDIR:-freebsd/15.1_diskless}"
PIDF=/tmp/fbsd-diskless-test-dnsmasq.pid

case "${1:-}" in
setup)
	ip link show "${TAP}" >/dev/null 2>&1 || {
		sudo ip tuntap add dev "${TAP}" mode tap user "$(id -un)"
		sudo ip addr add ${GW}/24 dev "${TAP}"
		sudo ip link set "${TAP}" up
	}
	sudo mkdir -p /etc/exports.d
	echo "${ROOT} ${NET}(ro,no_root_squash,insecure,no_subtree_check,fsid=15101)" | sudo tee "${EXPORT_FILE}" >/dev/null
	sudo exportfs -ra
	exit 0 ;;
stop)
	for f in /tmp/fbsd-diskless-*/qemu.pid; do
		[[ -f "${f}" ]] && kill "$(<"${f}")" 2>/dev/null || true
	done
	exit 0 ;;
teardown)
	"$0" stop
	sudo pkill -F "${PIDF}" 2>/dev/null || true
	sudo ip link del "${TAP}" 2>/dev/null || true
	sudo rm -f "${EXPORT_FILE}" "/srv/tftp/${SUB}/test.ipxe"
	sudo rmdir /etc/exports.d 2>/dev/null || true
	sudo exportfs -ra
	exit 0 ;;
run) shift ;;
*) sed -n '2,/^set -e/p' "$0" | sed '$d' >&2; exit 2 ;;
esac

MODE="${1:?bios|uefi}"; shift
NIC=virtio-net-pci MAC=52:54:00:fb:15:01 MEM=2048 SECS=150 KEEP="" IPXE=""
while getopts n:m:r:d:o:ki opt; do
	case "${opt}" in
	n) NIC="${OPTARG}" ;; m) MAC="${OPTARG}" ;; r) MEM="${OPTARG}" ;;
	d) SECS="${OPTARG}" ;; o) OUT="${OPTARG}" ;; k) KEEP=1 ;; i) IPXE=1 ;;
	*) exit 2 ;;
	esac
done
OUT="${OUT:-/tmp/fbsd-diskless-${MODE}-${NIC}}"
rm -rf "${OUT}"; mkdir -p "${OUT}"
ip link show "${TAP}" >/dev/null || { echo "run '$0 setup' first" >&2; exit 1; }
HOSTNAME_DHCP="fbtest-${NIC%%-*}"

cat >"${OUT}/dnsmasq.conf" <<CONF
interface=${TAP}
bind-interfaces
port=0
dhcp-range=10.98.0.100,10.98.0.120,12h
dhcp-option=3,${GW}
dhcp-option=6,${GW}
log-dhcp
dhcp-leasefile=${OUT}/leases
pid-file=${PIDF}
dhcp-host=${MAC},${HOSTNAME_DHCP}
dhcp-match=set:bios,option:client-arch,0
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-match=set:ipxe,175
CONF
if [[ -n "${IPXE}" ]]; then
	cat >>"${OUT}/dnsmasq.conf" <<CONF
dhcp-boot=tag:ipxe,${SUB}/test.ipxe,,${HUB}
dhcp-boot=tag:!ipxe,tag:bios,ipxe/undionly.kpxe,,${HUB}
dhcp-boot=tag:!ipxe,tag:efi64,ipxe/snponly.efi,,${HUB}
CONF
	{
		printf '#!ipxe\nisset ${srv} || set srv ${next-server}\ngoto freebsd-15.1-diskless\n'
		sed -n '/^:freebsd-15.1-diskless/,$p' "$(dirname -- "$0")/ipxe-menu-fragment.txt"
		printf ':failed\necho Boot failed\nshell\n'
	} | sudo tee "/srv/tftp/${SUB}/test.ipxe" >/dev/null
else
	cat >>"${OUT}/dnsmasq.conf" <<CONF
dhcp-boot=tag:bios,${SUB}/pxeboot,,${HUB}
dhcp-boot=tag:efi64,${SUB}/loader_pxe.efi,,${HUB}
CONF
fi
sudo pkill -F "${PIDF}" 2>/dev/null || true
sudo dnsmasq -C "${OUT}/dnsmasq.conf" --log-facility="${OUT}/dnsmasq.log"
cleanup() { sudo pkill -F "${PIDF}" 2>/dev/null || true; sudo rm -f "/srv/tftp/${SUB}/test.ipxe"; [[ -n "${KEEP}" ]] || kill "${QP:-0}" 2>/dev/null || true; }
trap cleanup EXIT

case "${NIC}" in
virtio-net-pci) ROM_UEFI="" ;;
*) ROM_UEFI=",romfile=efi-${NIC}.rom" ;;
esac
COMMON=(-m "${MEM}" -display none -serial "file:${OUT}/serial.log" -vga std
	-monitor "unix:${OUT}/mon,server,nowait" -boot n
	-netdev "tap,id=n0,ifname=${TAP},script=no,downscript=no")
[[ -w /dev/kvm ]] && COMMON+=(-enable-kvm -cpu host)
if [[ "${MODE}" == uefi ]]; then
	cp /usr/share/OVMF/OVMF_VARS_4M.fd "${OUT}/vars.fd"
	QEMU=(qemu-system-x86_64 -machine q35 "${COMMON[@]}" -device "${NIC},netdev=n0,mac=${MAC}${ROM_UEFI:-,romfile=}"
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
		-drive "if=pflash,format=raw,file=${OUT}/vars.fd")
else
	QEMU=(qemu-system-x86_64 "${COMMON[@]}" -device "${NIC},netdev=n0,mac=${MAC}")
fi
"${QEMU[@]}" &
QP=$!
echo "${QP}" >"${OUT}/qemu.pid"
mon() { echo "$1" | socat - "unix-connect:${OUT}/mon" >/dev/null 2>&1 || true; }
for ((t = 10; t <= SECS && $(kill -0 "${QP}" 2>/dev/null; echo $?) == 0; t += 10)); do
	sleep 10
	if grep -qa "login:" "${OUT}/serial.log" 2>/dev/null && [[ -z "${seen:-}" ]]; then seen=$t; fi
	mon "screendump ${OUT}/s${t}.ppm"
	sleep 1
	convert "${OUT}/s${t}.ppm" "${OUT}/s${t}.png" 2>/dev/null && rm -f "${OUT}/s${t}.ppm"
done
echo "guest ip: $(awk '{print $3}' "${OUT}/leases" 2>/dev/null | head -1)  (out: ${OUT})"
if [[ -n "${KEEP}" ]]; then trap - EXIT; echo "qemu pid ${QP} left running (diskless/freebsd/qemu-test.sh stop)"; fi
