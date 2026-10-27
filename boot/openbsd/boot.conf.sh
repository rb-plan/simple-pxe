#!/bin/bash
# Print the contents of the TFTP /etc/boot.conf for the OpenBSD installer.
# Used by boot/openbsd/stage-tftp.sh. OPENBSD_CONSOLE=com0 (default): serial console, the
# screen only shows the loader up to "switching console to com0" (OpenBSD has one console);
# OPENBSD_CONSOLE=tty0: screen console, no serial.
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
openbsd_defaults
if [[ "${OPENBSD_CONSOLE}" == com0 ]]; then
	echo "stty com0 ${OPENBSD_COM0_SPEED}"
	echo "set tty com0"
fi
echo "boot tftp:/openbsd/bsd.rd"
