/* Serial console in addition to the graphical/firmware console (BIOS: VGA, UEFI: ConOut).
 * COM1 (ttyS0), 115200 8N1 are the iPXE defaults (config/serial.h), so the menu and all
 * messages appear on a VM/server serial console as well as on the screen, and the menu can
 * be driven from either. */
#define CONSOLE_SERIAL
