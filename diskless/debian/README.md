# Diskless Debian (trixie) over iPXE: squashfs from HTTP, tmpfs overlay

A small Debian image that boots from the network and runs entirely from RAM (live-boot).
Nothing is written to a disk; everything outside the image is gone at the next reboot.

```
firmware -> DHCP -> iPXE 2.x (ipxe/boot.ipxe, the single boot menu, entry "Debian trixie diskless")
   kernel + initrd over HTTP   http://10.20.0.26/images/debian-trixie-diskless/current/{vmlinuz,initrd.img}
   initramfs (live-boot)       ip=dhcp, then wget .../current/filesystem.squashfs into a ramfs
   squashfs (read-only) + tmpfs overlay = /       -> systemd -> sshd / getty
```

## Build

    diskless/debian/build.sh            # no root, no sudo (mmdebstrap --mode=unshare)
    diskless/debian/build.sh verify /srv/pxe-images/debian-trixie-diskless/<id>
    diskless/debian/build.sh prune

* `packages.list`: what goes in (Recommends are not installed).
* `overlay/`: files copied into the image (networkd DHCP, sshd drop-in, initramfs config,
  dpkg slimming, hostname fallback service).
* `hooks/customize.sh`: time zone, locale, user, ssh keys + host keys, services, exports
  kernel/initrd; `hooks/tidy.sh`: removes the staged secrets again.
* `gen-secrets.sh`: creates the shared SSH host keys and the console password (idempotent).
* Output: `/srv/pxe-images/debian-trixie-diskless/<YYYYMMDD-HHMM>/` with
  `filesystem.squashfs vmlinuz initrd.img SHA256SUMS MANIFEST packages.txt
  ssh-host-fingerprints.txt authorized-key-fingerprints.txt`; `current` is a relative symlink
  switched atomically (`mv -T`) only after `verify` passed (checksums, squashfs readable, host
  keys identical to the stored ones, root locked, machine-id empty, time zone, initrd has
  live-boot + NIC drivers + Realtek firmware). The newest `KEEP` (3) builds are kept; the one
  `current` points to is never deleted.
* Variables (environment or `build.conf`, which is not in git): `SUITE` (trixie), `MIRROR`
  (build mirror; default the hub mirror `http://10.20.0.26/debian`, no public source),
  `RUNTIME_MIRROR` / `RUNTIME_SECURITY_MIRROR` (written into the image's apt sources, default
  the hub mirror), `COMPONENTS` (`main non-free-firmware`), `TZ_NAME` (`Asia/Taipei`),
  `DEFAULT_HOSTNAME` (`trixie-diskless`), `ADMIN_USER` (`nick`), `AUTHORIZED_KEYS`
  (`~/.ssh/authorized_keys`), `OUT_ROOT`, `SECRETS_DIR`, `KEEP`, `MODE` (`unshare`;
  `fakeroot` if user namespaces are unavailable), `SQUASHFS_COMP` / `SQUASHFS_LEVEL`.
* Compression: squashfs with **zstd -19, 256K blocks**. zstd decompresses several times faster
  than xz (matters on slow CPUs and while the kernel reads the root), xz would be ~10-15 %
  smaller, which only saves a download of a few tens of MB on a LAN. `SQUASHFS_COMP=xz` works.
* Re-running with the same inputs is *not* bit-for-bit reproducible (the mirror moves, apt
  picks the newest package versions); `packages.txt` records exactly what was installed. Use
  a pinned mirror snapshot for that.

### Secrets (never in git, never under a web root)

    /srv/pxe-images/secrets/                 0700 nick
    /srv/pxe-images/secrets/ssh-host/        0700: ssh_host_{ed25519,ecdsa,rsa}_key (0600) + .pub
    /srv/pxe-images/secrets/nick-console-password   0600 (plain text, only the sha512 hash is baked)

All machines share the one host key set (baked into `/etc/ssh`, nothing regenerates it).
**The squashfs therefore contains the private host keys and the password hash**, so
`/images/` is restricted to private networks in nginx (`boot/nginx/images-location.conf`) and
must never be exposed publicly. Anyone who can read the squashfs can impersonate the machines.
`gen-secrets.sh --rotate` replaces all of it (clients will see a host key change).

## Boot parameters

    boot=live fetch=http://10.20.0.26/images/debian-trixie-diskless/current/filesystem.squashfs ip=dhcp console=tty0 console=ttyS0,115200n8

* `boot=live`: use live-boot's initramfs scripts.
* `fetch=URL`: live-boot downloads the squashfs (`wget`, plain `http://`) into a ramfs and
  mounts it; the file name must end in `.squashfs`.
* `ip=dhcp`: configure the NIC with DHCP in the initramfs (klibc `ipconfig`) so the download
  works; systemd-networkd in the running system takes over (hostname from the lease; if there
  is none, `diskless-hostname-fallback.service` sets `trixie-diskless`).
* `console=tty0 console=ttyS0,115200n8`: kernel log and console on the screen and on the serial
  port (115200 8N1, e.g. the vmsrt serial console); the last `console=` (ttyS0) is `/dev/console`,
  so initramfs messages and early boot output also go to serial. The login prompt on ttyS0 needs
  `serial-getty@ttyS0.service` in the image (systemd starts it automatically for a `console=ttyS0`
  kernel argument via `systemd-getty-generator`; an explicit enable in the rootfs is more robust).
  Changed with `PXE_IPXE_CONSOLE_ARGS` (config.local).
* Extra arguments: iPXE appends `${diskless_args}` last, which a per-machine script can set, e.g.
  `ipxe/mac-aa-bb-cc-dd-ee-ff.ipxe`: `set diskless_args console=tty0` (a later `console=` wins as `/dev/console`).

## Menus

* iPXE (`./simple-pxe ipxe-menu`, run by `boot/build-tftp-stage.sh` -> `ipxe/boot.ipxe`): entry
  "Debian trixie diskless (RAM, ssh key login)" in the group "Diskless" of the one boot menu
  (BIOS and UEFI use the same entry, the kernel and initrd come straight from HTTP). Variables:
  `PXE_DISKLESS_DEBIAN` (`auto`: only if `<PXE_IMAGES_ROOT>/debian-trixie-diskless/current/vmlinuz`
  exists, `1`, `0`), `PXE_IMAGES_URL`, `PXE_DISKLESS_DEBIAN_ARGS`, `PXE_DISKLESS_DEBIAN_TITLE`.
* GRUB (`menu.d/diskless-debian.sh`; add `diskless-debian` to `PXE_MENUS` in `config.local`,
  then `./simple-pxe menu`): same image, same variables. GRUB loads big files slowly and is only
  the legacy fallback entry of the iPXE menu; use the iPXE entry.

After changing the stage: `./boot/build-tftp-stage.sh && sudo rsync -ac --delete
--chown=root:root --chmod=D755,F644 /srv/pxe-data/tftp-stage/ /srv/tftp/`.

## Serving

`boot/nginx/images-location.conf` (installed as `/opt/bsdfile/nginx/hub/images-location.inc`
and included in the `:80` and `:443` servers): only `/images/debian-trixie-diskless/` is
mapped (to `/srv/pxe-images/debian-trixie-diskless/`, autoindex on, private networks only); the
rest of `/srv/pxe-images` (`secrets/`, `.work/`, `.cache/`) is not under any alias and
everything else below `/images/` returns 404.

## Login

User `nick` (uid 1000, group `sudo`): SSH key login with the public keys from
`~/.ssh/authorized_keys` of the build user at build time (fingerprints in
`authorized-key-fingerprints.txt`); SSH password login and root login are off, root has no
password. The console (and `sudo`) password is in `/srv/pxe-images/secrets/nick-console-password`.

## Serial console (VM serial console, ttyS0 115200 8N1)

* The image enables `serial-getty@ttyS0.service` (`getty.target.wants`) with the drop-in
  `overlay/etc/systemd/system/serial-getty@ttyS0.service.d/10-diskless.conf`, which fixes the
  speed to 115200 (the stock unit uses `--keep-baud` and would stay at 9600 when the kernel
  command line has no `console=ttyS0`). If a machine has no ttyS0 the unit simply never starts.
  There is no autologin: log in as `nick` (console password file, see Login) on ttyS0.
  `build.sh verify` checks that the unit is enabled and the drop-in is present.
* Kernel messages on the serial port need `console=` on the kernel command line. The iPXE menu
  (`boot/gen-boot-ipxe.sh`) appends `PXE_IPXE_CONSOLE_ARGS` (default
  `console=tty0 console=ttyS0,115200n8`) to the diskless entry; the last `console=` is
  `/dev/console`, so ttyS0 is the system console and tty0 still shows the kernel log and a
  tty1 login. Per machine: `set diskless_args ...` in `ipxe/mac-<mac>.ipxe`.
* Without any `console=` the login prompt still appears on ttyS0 (but no kernel log).
* Connect from vmsrt: `virsh console vmsrt` (leave with Ctrl+]) or `virsh -c qemu:///system console vmsrt`.

## Periodic rebuild (disabled by default)

`systemd/diskless-debian-build.{service,timer}` run `build.sh` as `nick` on Sunday 05:00.
Installed in `/etc/systemd/system` but **not enabled**; enable with:

    sudo systemctl enable --now diskless-debian-build.timer

## Limits / notes

* The switch of `current` is atomic, but iPXE fetches kernel/initrd first and the initramfs
  fetches the squashfs a few seconds later; a client booting exactly while `current` moves
  would mix two builds (module mismatch). Weekly rebuilds make that very unlikely.
* iPXE 2.0.0 (built by `boot/ipxe/build.sh`) passes the initrd to the kernel under UEFI too (EFI
  LoadFile2), so the former workaround (a small GRUB image `grubnetx64-diskless.efi` for UEFI)
  is gone and `${diskless_args}` now works for BIOS and UEFI. The menu entry still runs
  `imgfree` before `kernel`: iPXE would otherwise also hand registered images (the running
  `boot.ipxe`, a per-MAC script) to the kernel as extra initrds.
* `zstd` is in `packages.list` so the initrd is zstd-compressed (initramfs-tools falls back to
  gzip without it).
* `fortunes` only Recommends `fortune-mod` (the binary), so it is listed explicitly; `dnsutils`
  is a transitional name in trixie, `bind9-dnsutils` is listed instead.
* `verify-guest.sh <ip> [hostname]` checks a booted guest over SSH (host keys, auth rules, tools,
  packages, memory); used for the QEMU tests.
* BIOS/UEFI, Secure Boot must stay off (iPXE/GRUB binaries are unsigned).
