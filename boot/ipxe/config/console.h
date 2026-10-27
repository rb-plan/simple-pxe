/* Serial console (COM1 = ttyS0, 115200 8N1: the iPXE defaults in config/serial.h) in
 * addition to VGA on BIOS builds, so the menu and messages show on a VM/server serial
 * console and the menu can be driven from either.
 * Not for UEFI builds: there the firmware's ConOut already goes to the serial port when
 * the platform has console redirection (OVMF/QEMU -serial, server BIOS "serial console
 * redirection"); also enabling CONSOLE_SERIAL would print every character twice. */
#if defined ( PLATFORM_pcbios )
  #define CONSOLE_SERIAL
#endif
