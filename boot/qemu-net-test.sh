#!/bin/bash
# Full-stack PXE test in QEMU: real DHCP (dnsmasq with the arch/MAC rules from
# boot/README.md) on a private tap, TFTP/HTTP/NFS from this host. Nothing touches the
# production network.
#
#   boot/qemu-net-test.sh setup                 # once: tap pxetest0 10.99.0.1/24 + NFS export for 10.99.0.0/24
#                                               # (PXE_TEST_TAP/NETPFX/FSID select another tap+net, so parallel runs do not collide)
#   boot/qemu-net-test.sh run bios|uefi [options]
#   boot/qemu-net-test.sh teardown              # remove tap and the test export
#
# Options for run:
#   -m MAC        client MAC (default 52:54:00:fb:00:03). 52:54:00:fb:00:01 gets the
#                 FreeBSD 15.1 loader directly (see the dhcp rules below).
#   -k "KEYS"     QEMU sendkey names to press, one per second, e.g. "1" or
#                 "down down ret" (needs -t)
#   -t SECS       when to press the keys (default 25)
#   -d SECS       how long to run (default 120); a screenshot is taken every 10 s
#   -s "T1 T2.."  extra screenshots at these seconds (out dir: x<T>.png), e.g. to catch the menu
#   -r MB         guest RAM (default 1536; 2048 for the diskless Debian test)
#   -o DIR        output directory (default /tmp/pxe-net-test-<mode>)
#
# BIOS clients use QEMU's iPXE option ROM (so they already speak iPXE); UEFI clients use
# OVMF's own PXE stack with virtio-net (no option ROM), i.e. the real firmware path
# DHCP -> snponly.efi -> boot.ipxe. Needs sudo for the tap, dnsmasq and exports.
# TFTP must already serve the staged files (tftpd-hpa on /srv/tftp).
#
# Environment:
#   PXE_TEST_NAT=1             setup/teardown: masquerade 10.99.0.0/24 to the outside (needed for entries
#                              that fetch from an upstream mirror) and run: PXE_TEST_DNS=<resolver>
#   PXE_TEST_NO_NFS=1          setup/teardown: only the tap, no NFS export (diskless Debian test)
#   PXE_TEST_DHCP_HOSTNAME=x   DHCP hands out hostname x to the client MAC (checks hostname-from-DHCP)
#   PXE_TEST_FORCE_FIRST_STAGE=1  the client MAC is always given the first-stage binary
#                              (ipxe/undionly.kpxe for BIOS, ipxe/snponly.efi for UEFI), even if
#                              it already is iPXE. QEMU's BIOS NIC ROM and the EFI e1000/rtl8139
#                              ROMs are old iPXE builds; this makes them chain the new iPXE
#                              (so undionly.kpxe really runs, and the embedded script is tested)
#   PXE_TEST_NIC_MODEL / PXE_TEST_NIC_ROM / PXE_TEST_EXTRA_NIC: see below
# The client's lease is in <out dir>/leases, its serial console in <out dir>/serial.log.

set -euo pipefail

cd "$(dirname -- "$0")/.."
source config.local

HUB="${PXE_TEST_HUB_IP:-10.20.0.26}"
TAP="${PXE_TEST_TAP:-pxetest0}"
NETPFX="${PXE_TEST_NETPFX:-10.99.0}"
TESTNET="${NETPFX}.0/24"
if [[ "${TAP}" == pxetest0 ]]; then SUFFIX=""; else SUFFIX="-${TAP}"; fi
EXPORT_FILE="/etc/exports.d/pxe-qemu-test${SUFFIX}.exports"
PIDFILE="/tmp/pxe-net-test${SUFFIX}.pid"
FSID="${PXE_TEST_FSID:-20261027}"

case "${1:-}" in
setup)
	sudo ip tuntap add dev "${TAP}" mode tap user "$(id -un)"
	sudo ip addr add "${NETPFX}.1/24" dev "${TAP}"
	sudo ip link set "${TAP}" up
	[[ -z "${PXE_TEST_NAT:-}" ]] || sudo iptables -t nat -A POSTROUTING -s "${TESTNET}" ! -o "${TAP}" -j MASQUERADE
	if [[ -z "${PXE_TEST_NO_NFS:-}" ]]; then
		sudo mkdir -p /etc/exports.d
		echo "${PXE_NFS_ROOT} ${TESTNET}(ro,no_root_squash,no_subtree_check,insecure,fsid=${FSID})" | sudo tee "${EXPORT_FILE}" >/dev/null
		sudo exportfs -ra
	fi
	exit 0
	;;
teardown)
	sudo pkill -F "${PIDFILE}" 2>/dev/null || true
	sudo iptables -t nat -D POSTROUTING -s "${TESTNET}" ! -o "${TAP}" -j MASQUERADE 2>/dev/null || true
	sudo ip link del "${TAP}" 2>/dev/null || true
	if [[ -z "${PXE_TEST_NO_NFS:-}" ]]; then
		sudo rm -f "${EXPORT_FILE}"
		sudo rmdir /etc/exports.d 2>/dev/null || true
		sudo exportfs -ra
	fi
	exit 0
	;;
run) shift ;;
*) sed -n '2,/^set -e/p' "$0" | sed '$d' >&2; exit 2 ;;
esac

MODE="${1:?bios|uefi}"; shift
MAC=52:54:00:fb:00:03 KEYS="" KEYAT=25 SECS=120 MEM=1536 SHOTS=""
while getopts m:k:t:d:r:o:s: opt; do
	case "${opt}" in
	m) MAC="${OPTARG}" ;; k) KEYS="${OPTARG}" ;; t) KEYAT="${OPTARG}" ;;
	d) SECS="${OPTARG}" ;; r) MEM="${OPTARG}" ;; s) SHOTS="${OPTARG}" ;; o) OUT="${OPTARG}" ;;
	*) exit 2 ;;
	esac
done
OUT="${OUT:-/tmp/pxe-net-test-${MODE}}"
rm -rf "${OUT}"; mkdir -p "${OUT}"
ip link show "${TAP}" >/dev/null || { echo "run '$0 setup' first" >&2; exit 1; }

cat >"${OUT}/dnsmasq.conf" <<EOF
interface=${TAP}
bind-interfaces
port=0
dhcp-range=${NETPFX}.100,${NETPFX}.120,12h
dhcp-option=3,${NETPFX}.1
${PXE_TEST_DNS:+dhcp-option=6,${PXE_TEST_DNS}}
log-dhcp
dhcp-leasefile=${OUT}/leases
pid-file=${PIDFILE}
dhcp-match=set:bios,option:client-arch,0
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-match=set:ipxe,175
dhcp-host=52:54:00:fb:00:01,set:fbsd151
dhcp-boot=tag:fbsd151,tag:bios,freebsd/15.1_amd64/pxeboot,,${HUB}
dhcp-boot=tag:fbsd151,tag:efi64,freebsd/15.1_amd64/loader_pxe.efi,,${HUB}
dhcp-boot=tag:!fbsd151,tag:!forcefirst,tag:ipxe,ipxe/boot.ipxe,,${HUB}
dhcp-boot=tag:!fbsd151,tag:!forcefirst,tag:!ipxe,tag:bios,ipxe/undionly.kpxe,,${HUB}
dhcp-boot=tag:!fbsd151,tag:!forcefirst,tag:!ipxe,tag:efi64,ipxe/snponly.efi,,${HUB}
dhcp-boot=tag:forcefirst,tag:bios,ipxe/undionly.kpxe,,${HUB}
dhcp-boot=tag:forcefirst,tag:efi64,ipxe/snponly.efi,,${HUB}
EOF
[[ -n "${PXE_TEST_FORCE_FIRST_STAGE:-}" ]] && echo "dhcp-host=${MAC},set:forcefirst" >>"${OUT}/dnsmasq.conf"
[[ -n "${PXE_TEST_DHCP_HOSTNAME:-}" ]] && echo "dhcp-host=${MAC},${PXE_TEST_DHCP_HOSTNAME}" >>"${OUT}/dnsmasq.conf"
# Production DHCP is not on the TFTP host: a plain DHCP request (no option 93/175, e.g.
# GRUB's net_bootp) gets the DHCP server's own address as siaddr, not the hub. On this
# test tap dnsmasq runs on the hub, which would hide that. PXE_TEST_OTHER_SIADDR
# (default 10.99.0.99, set to "" to disable) reproduces the production behaviour.
OTHER_SIADDR="${PXE_TEST_OTHER_SIADDR-${NETPFX}.99}"
if [[ -n "${OTHER_SIADDR}" ]]; then
	echo "dhcp-boot=tag:!fbsd151,tag:!forcefirst,tag:!ipxe,tag:!bios,tag:!efi64,unused.bin,,${OTHER_SIADDR}" >>"${OUT}/dnsmasq.conf"
fi
sudo pkill -F "${PIDFILE}" 2>/dev/null || true
sudo dnsmasq -C "${OUT}/dnsmasq.conf" --log-facility="${OUT}/dnsmasq.log"
trap 'sudo pkill -F "${PIDFILE}" 2>/dev/null || true' EXIT

COMMON=(-m "${MEM}" -display none -serial "file:${OUT}/serial.log" -vga std
	-monitor "unix:${OUT}/mon,server,nowait" -boot n
	-netdev "tap,id=n0,ifname=${TAP},script=no,downscript=no")
[[ -w /dev/kvm ]] && COMMON+=(-enable-kvm -cpu host)
if [[ "${MODE}" == uefi ]]; then
	cp /usr/share/OVMF/OVMF_VARS_4M.fd "${OUT}/vars.fd"
	QEMU=(qemu-system-x86_64 -machine q35 "${COMMON[@]}" -device "${PXE_TEST_NIC_MODEL:-virtio-net-pci},netdev=n0,mac=${MAC}${PXE_TEST_NIC_ROM-,romfile=}"
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
		-drive "if=pflash,format=raw,file=${OUT}/vars.fd")
else
	QEMU=(qemu-system-x86_64 "${COMMON[@]}" -device "${PXE_TEST_NIC_MODEL:-e1000},netdev=n0,mac=${MAC}")
fi
# PXE_TEST_NIC_MODEL / PXE_TEST_NIC_ROM: NIC model (e1000, rtl8139, ...); for UEFI set
# PXE_TEST_NIC_ROM="" to use the model's EFI option ROM (OVMF has no e1000/rtl8139 driver).
# PXE_TEST_EXTRA_NIC=1 adds a second NIC on QEMU user networking (its DHCP offers
# siaddr 10.0.2.2, no TFTP), like a VM with two NICs on different networks.
if [[ -n "${PXE_TEST_EXTRA_NIC:-}" ]]; then
	QEMU+=(-netdev user,id=n1 -device "${PXE_TEST_EXTRA_NIC_MODEL:-virtio-net-pci},netdev=n1,mac=52:54:00:fb:99:03,romfile=")
fi
"${QEMU[@]}" &
QP=$!
mon() { echo "$1" | socat - "unix-connect:${OUT}/mon" >/dev/null 2>&1 || true; }
if [[ -n "${KEYS}" ]]; then
	( sleep "${KEYAT}"; for k in ${KEYS}; do mon "sendkey ${k}"; sleep 1; done ) &
fi
if [[ -n "${SHOTS}" ]]; then
	( T0=0; for t in ${SHOTS}; do sleep $((t - T0)); T0=${t}; mon "screendump ${OUT}/x${t}.ppm"; sleep 1; T0=$((T0 + 1))
		convert "${OUT}/x${t}.ppm" "${OUT}/x${t}.png" 2>/dev/null && rm -f "${OUT}/x${t}.ppm"; done ) &
fi
for ((t = 10; t <= SECS && $(kill -0 "${QP}" 2>/dev/null; echo $?) == 0; t += 10)); do
	sleep 10
	mon "screendump ${OUT}/s${t}.ppm"
	sleep 1
	convert "${OUT}/s${t}.ppm" "${OUT}/s${t}.png" 2>/dev/null && rm -f "${OUT}/s${t}.ppm"
done
mon quit
sleep 1
kill "${QP}" 2>/dev/null || true
echo "screenshots and logs in ${OUT} (last: s*.png); NFS root mounts seen by mountd:"
sudo journalctl -t rpc.mountd --no-pager --since "-$((SECS + 60)) sec" 2>/dev/null | grep -a "${NETPFX//./\\.}\\." | sed -E 's/.*for (\S+) .*/  \1/' | sort | uniq -c || true
