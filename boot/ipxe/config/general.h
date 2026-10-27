/* Local iPXE feature switches for simple-pxe (copied to src/config/local/general.h by build.sh).
 * Upstream defaults already include TFTP, HTTP, HTTPS, DNS, CONSOLE_CMD, REBOOT_CMD,
 * POWEROFF_CMD, IMAGE_SCRIPT, bzImage/ELF/PXE/EFI images, and (for UEFI) Linux initrd
 * passing through the EFI LoadFile2 protocol. Only extras are listed here. */

#define IMAGE_TRUST_CMD		/* imgtrust / imgverify */
#define PING_CMD		/* ping */
#define NSLOOKUP_CMD		/* nslookup */
#define IPSTAT_CMD		/* ipstat */
#define NEIGHBOUR_CMD		/* nstat / arp-like neighbour table */
#define TIME_CMD		/* time */
