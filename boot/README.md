# First-stage network boot (BIOS + UEFI)

`build-tftp-stage.sh` builds the TFTP tree into `${PXE_LOCAL_ROOT}/tftp-stage`
(not served over HTTP; nginx must return 403 for `/pxe/tftp-stage/`):

| File (TFTP path) | What |
|---|---|
| `ipxe/undionly.kpxe`, `ipxe/snponly.efi` | iPXE first stage (BIOS / UEFI x64), from `PXE_IPXE_DIR` (default `${PXE_DOWNLOADS}/ipxe`, then `/usr/lib/ipxe`) |
| `ipxe/boot.ipxe` | generated iPXE menu: GRUB, or one entry per FreeBSD tree; optional per-machine script `ipxe/mac-aa-bb-cc-dd-ee-ff.ipxe` |
| `grub/i386-pc/core.0`, `grub/x86_64-efi/grubnetx64.efi` | GRUB loaded straight by the firmware (prefix `/grub`) |
| `grub/i386-pc/core-ipxe.0`, `grub/x86_64-efi/grubnetx64-ipxe.efi` | the same GRUB when started from iPXE (runs `net_bootp` first) |
| `grub/grub.cfg`, `grub/grub.cfg.d/default` | read by all GRUB images; `default` points at the HTTP `root.menu` |
| `freebsd/<ver>_amd64/pxeboot`, `.../loader_pxe.efi` | FreeBSD BIOS / UEFI loaders with the NFS root patched in (`prepare.d/freebsd.sh`) |

Copy the stage to the TFTP root (`/srv/tftp` for tftpd-hpa):

    sudo rsync -a --delete --chown=root:root --chmod=D755,F644 ${PXE_LOCAL_ROOT}/tftp-stage/ /srv/tftp/

GRUB then loads `(http,<host>)<path of PXE_HTTP_ROOT>/menu/root.menu` over plain HTTP.
Use an IP address in `PXE_HTTP_ROOT` if the DHCP-provided DNS is slow or missing
(GRUB sometimes drops the first DNS query).

## Why FreeBSD is not started from GRUB

* UEFI: GRUB keeps the NIC open exclusively; FreeBSD `loader.efi` then fails with
  "Unable to open network interface 0 for exclusive access: 15". There is no GRUB
  command that releases it (`rmmod efinet` fails: the `chain` module references it).
* BIOS: `kfreebsd` + `kfreebsd_module cd.iso type=mfs_root` loads the ISO and then the
  machine resets (reproduced with FreeBSD 14.5 and 15.1 in QEMU); GRUB cannot chain
  `pxeboot` because it needs the PXE stack as the firmware left it.

FreeBSD is booted directly by the firmware (DHCP filename) or by iPXE. The NFS root is
patched into the loaders, so no DHCP root-path option is needed; the NFS server is the
DHCP `next-server`. Boot flow: loader (TFTP) -> kernel and `/boot` over NFS (UDP, v3) ->
kernel mounts the same NFS root -> `rc.initdiskless` mounts `cd.iso` -> installer.

NFS export (`/etc/exports`): `<PXE_NFS_ROOT> 10.20.0.0/16(ro,no_root_squash,no_subtree_check,insecure)`
plus `udp=y` / `vers3=y` for nfsd (`/etc/nfs.conf.d/pxe-udp.conf`).

## DHCP (dnsmasq syntax; `next-server` is the TFTP + NFS host)

| Client | Condition | `filename` |
|---|---|---|
| iPXE (option 175) | any, unless FreeBSD-tagged | `ipxe/boot.ipxe` |
| BIOS (option 93 = 0) | default | `ipxe/undionly.kpxe` |
| UEFI x64 (option 93 = 7 or 9) | default | `ipxe/snponly.efi` |
| FreeBSD 15.1 / 14.5, BIOS | per machine (MAC tag) | `freebsd/15.1_amd64/pxeboot` / `freebsd/14.5_amd64/pxeboot` |
| FreeBSD 15.1 / 14.5, UEFI x64 | per machine (MAC tag) | `freebsd/15.1_amd64/loader_pxe.efi` / `freebsd/14.5_amd64/loader_pxe.efi` |
| Without iPXE (Linux only) | BIOS / UEFI | `grub/i386-pc/core.0` / `grub/x86_64-efi/grubnetx64.efi` |

    dhcp-match=set:bios,option:client-arch,0
    dhcp-match=set:efi64,option:client-arch,7
    dhcp-match=set:efi64,option:client-arch,9
    dhcp-match=set:ipxe,175
    dhcp-host=aa:bb:cc:dd:ee:ff,set:fbsd151        # machines that should boot FreeBSD 15.1 directly
    dhcp-boot=tag:fbsd151,tag:bios,freebsd/15.1_amd64/pxeboot,,10.20.0.26
    dhcp-boot=tag:fbsd151,tag:efi64,freebsd/15.1_amd64/loader_pxe.efi,,10.20.0.26
    dhcp-boot=tag:!fbsd151,tag:ipxe,ipxe/boot.ipxe,,10.20.0.26
    dhcp-boot=tag:!fbsd151,tag:!ipxe,tag:bios,ipxe/undionly.kpxe,,10.20.0.26
    dhcp-boot=tag:!fbsd151,tag:!ipxe,tag:efi64,ipxe/snponly.efi,,10.20.0.26

The MAC-tagged lines are optional: without them FreeBSD is chosen from the iPXE menu.

## Testing

`qemu-smoke.sh bios|uefi` boots the GRUB images directly in QEMU/OVMF (user-mode
networking) and checks that the menu is reached over HTTP.

`qemu-net-test.sh` is the full-stack test: private tap + dnsmasq with the DHCP rules
above, real TFTP/HTTP/NFS; see the header of the script (`setup`, `run`, `teardown`).

`nginx/pxe-location.conf` is the nginx snippet that serves `PXE_LOCAL_ROOT` at `/pxe/`
(include it in the `:80` server and, optionally, the HTTPS server).
