# First-stage network boot (BIOS + UEFI)

`build-tftp-stage.sh` builds GRUB network images into `${PXE_LOCAL_ROOT}/tftp-stage`
(not served over HTTP; nginx must return 403 for `/pxe/tftp-stage/`):

| File (TFTP path) | Client | DHCP `filename` |
|---|---|---|
| `grub/i386-pc/core.0` | legacy BIOS (option 93 = 0x0000) | `grub/i386-pc/core.0` |
| `grub/x86_64-efi/grubnetx64.efi` | UEFI x64 (option 93 = 0x0007 / 0x0009) | `grub/x86_64-efi/grubnetx64.efi` |
| `grub/grub.cfg`, `grub/grub.cfg.d/default` | read by both images (prefix `/grub`) | - |

Copy the stage to the TFTP root (`/srv/tftp` for tftpd-hpa):

    sudo rsync -a --chown=root:root --chmod=D755,F644 ${PXE_LOCAL_ROOT}/tftp-stage/ /srv/tftp/

GRUB then loads `(http,<host>)<path of PXE_HTTP_ROOT>/menu/root.menu` over plain HTTP.
Use an IP address in `PXE_HTTP_ROOT` if the DHCP-provided DNS is slow or missing
(GRUB sometimes drops the first DNS query).

`qemu-smoke.sh bios|uefi` boots the staged files in QEMU/OVMF (user-mode networking)
and checks that the menu is reached over HTTP.

`nginx/pxe-location.conf` is the nginx snippet that serves `PXE_LOCAL_ROOT` at `/pxe/`
(include it in the `:80` server and, optionally, the HTTPS server).
