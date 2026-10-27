# Diskless Debian (trixie) over iPXE: squashfs from HTTP, tmpfs overlay

A small Debian image that boots from the network and runs entirely from RAM (live-boot).
Nothing is written to a disk; everything outside the image is gone at the next reboot.

```
firmware -> DHCP -> iPXE (ipxe/boot.ipxe, menu "Debian trixie diskless")
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
  (build mirror; default upstream USTC; the hub mirror is `MIRROR=http://10.20.0.26/debian`),
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

    boot=live fetch=http://10.20.0.26/images/debian-trixie-diskless/current/filesystem.squashfs ip=dhcp

* `boot=live`: use live-boot's initramfs scripts.
* `fetch=URL`: live-boot downloads the squashfs (`wget`, plain `http://`) into a ramfs and
  mounts it; the file name must end in `.squashfs`.
* `ip=dhcp`: configure the NIC with DHCP in the initramfs (klibc `ipconfig`) so the download
  works; systemd-networkd in the running system takes over (hostname from the lease; if there
  is none, `diskless-hostname-fallback.service` sets `trixie-diskless`).
* Extra arguments: iPXE appends `${diskless_args}`, which a per-machine script can set, e.g.
  `ipxe/mac-aa-bb-cc-dd-ee-ff.ipxe`: `set diskless_args console=ttyS0,115200n8`.

## Menus

* iPXE (`boot/build-tftp-stage.sh` -> `ipxe/boot.ipxe`): entry "Debian trixie diskless (RAM, ssh
  key login)", key `d`; the default entry (GRUB) is unchanged. Variables: `PXE_DISKLESS_DEBIAN`
  (`auto`: only if `<PXE_IMAGES_ROOT>/debian-trixie-diskless/current/vmlinuz` exists, `1`, `0`),
  `PXE_IMAGES_URL`, `PXE_DISKLESS_DEBIAN_ARGS`, `PXE_DISKLESS_DEBIAN_TITLE`.
* GRUB (`menu.d/diskless-debian.sh`; add `diskless-debian` to `PXE_MENUS` in `config.local`,
  then `./simple-pxe menu`): same image, same variables. GRUB loads big files slowly, so the
  iPXE entry is preferred (on UEFI the iPXE entry itself hands over to a tiny GRUB image, see
  "Limits / notes").

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

## Periodic rebuild (disabled by default)

`systemd/diskless-debian-build.{service,timer}` run `build.sh` as `nick` on Sunday 05:00.
Installed in `/etc/systemd/system` but **not enabled**; enable with:

    sudo systemctl enable --now diskless-debian-build.timer

## Limits / notes

* The switch of `current` is atomic, but iPXE fetches kernel/initrd first and the initramfs
  fetches the squashfs a few seconds later; a client booting exactly while `current` moves
  would mix two builds (module mismatch). Weekly rebuilds make that very unlikely.
* The 2019 iPXE build on the TFTP server (Debian bookworm package) has two quirks, both
  handled in `boot/build-tftp-stage.sh`:
  * BIOS: iPXE passes every registered image (including the running `boot.ipxe` and a per-MAC
    script) to the kernel as additional initrds, which breaks unpacking ("invalid magic at start
    of compressed archive"). The diskless block therefore runs `imgfree` before `kernel`.
  * UEFI: this iPXE does not hand an initrd to Linux 6.x at all (kernel panic, no rootfs). For
    EFI the menu entry chains `grub/x86_64-efi/grubnetx64-diskless.efi`, a small GRUB image
    whose embedded script loads the same kernel/initrd over HTTP and boots. It cannot take
    `${diskless_args}` (so no per-MAC console= in the UEFI path). A newer iPXE build would make
    this unnecessary.
* `zstd` is in `packages.list` so the initrd is zstd-compressed (initramfs-tools falls back to
  gzip without it).
* `fortunes` only Recommends `fortune-mod` (the binary), so it is listed explicitly; `dnsutils`
  is a transitional name in trixie, `bind9-dnsutils` is listed instead.
* `verify-guest.sh <ip> [hostname]` checks a booted guest over SSH (host keys, auth rules, tools,
  packages, memory); used for the QEMU tests.
* BIOS/UEFI, Secure Boot must stay off (iPXE/GRUB binaries are unsigned).
