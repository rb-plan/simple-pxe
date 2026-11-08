#!/bin/bash
# Switch the vmsrt MACs between the iPXE menu (default) and OpenBSD direct boot in the
# dnsmasq on the DHCP box (OpenBSD, dnsmasq conf.d/pxe.conf). Run from the hub:
#
#   boot/openbsd/dhcp-obsd-toggle.sh status
#   boot/openbsd/dhcp-obsd-toggle.sh on      # vmsrt gets openbsd/pxeboot (BIOS) / openbsd/BOOTX64.EFI (UEFI)
#   boot/openbsd/dhcp-obsd-toggle.sh off     # back to ipxe/{undionly.kpxe,snponly.efi,boot.ipxe}
#
# Why: OpenBSD's efiboot cannot be chain-loaded by iPXE (the iPXE menu entry only shows a hint
# under UEFI), so OpenBSD UEFI install needs the firmware to load BOOTX64.EFI directly.
# Each change: backup of pxe.conf next to it, dnsmasq --test, restart; a failed test restores the
# backup and does not restart. The tag:obsd dhcp-boot lines and tag:!obsd on the defaults stay in
# the file (harmless without any host tagged obsd); only the dhcp-host lines are toggled.
#
# Env: DHCP_HOST (default nick@10.20.0.18), OBSD_MACS (space separated, default the two vmsrt MACs).
set -euo pipefail
action="${1:-status}"
DHCP_HOST="${DHCP_HOST:-nick@10.20.0.18}"
OBSD_MACS="${OBSD_MACS:-52:54:00:cc:5d:20 52:54:00:23:3f:c7}"
case "${action}" in on|off|status) ;; *) echo "usage: $0 on|off|status" >&2; exit 2 ;; esac

ssh -o BatchMode=yes "${DHCP_HOST}" "ACTION='${action}' MACS='${OBSD_MACS}' sh -s" <<'REMOTE'
set -eu
D=/opt/bsdfile/dnsmasq
CONF=$D/conf.d/pxe.conf
DM=/usr/local/sbin/dnsmasq
tagged() { grep -c '^dhcp-host=.*,set:obsd' "$CONF" || true; }
case "$ACTION" in
status)
	echo "pxe.conf: $(tagged) dhcp-host line(s) with set:obsd"
	grep -n -E '^dhcp-host=.*set:obsd|^dhcp-boot=' "$CONF"
	exit 0 ;;
esac
BAK=$D/pxe.conf.pre-toggle-$ACTION.bak-$(date +%Y%m%d-%H%M%S)
cp -p "$CONF" "$BAK"
TMP=$(mktemp /tmp/pxe.conf.XXXXXX)
if [ "$ACTION" = on ]; then
	{ for m in $MACS; do
		grep -q "^dhcp-host=$m,set:obsd" "$CONF" || echo "dhcp-host=$m,set:obsd"
	done; cat "$CONF"; } > "$TMP"
else
	grep -v '^dhcp-host=.*,set:obsd' "$CONF" > "$TMP" || true
fi
cp "$TMP" "$CONF"; rm -f "$TMP"
if doas $DM --test; then
	doas rcctl restart dnsmasq >/dev/null && doas rcctl check dnsmasq
	echo "$ACTION: done, $(tagged) set:obsd host line(s); backup $BAK"
else
	cp -p "$BAK" "$CONF"
	echo "dnsmasq --test failed, restored $BAK, not restarted" >&2
	exit 1
fi
REMOTE
