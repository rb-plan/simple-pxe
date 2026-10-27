# Diskless FreeBSD 15.1 (amd64): NFS root straight from the release tarballs

No installer. FreeBSD's own loader is fetched over TFTP, reads `/boot/loader.conf` and the
kernel from the NFS root (UDP, NFSv3), and the kernel mounts the same NFS root read-only;
`/etc`, `/var`, `/tmp`, `/home` are memory filesystems (`rc.initdiskless`, `diskless(8)`).

```
firmware -> DHCP (siaddr 10.20.0.26) -> [iPXE menu] -> TFTP freebsd/15.1_diskless/{pxeboot | loader_pxe.efi}
   loader: NFS 10.20.0.26:/srv/pxe-images/freebsd-15.1-diskless  (path baked into the binary)
   kernel (GENERIC) + serial/video console -> NFS root (ro) -> rc.initdiskless -> sshd, getty
```

## Build

    diskless/freebsd/build.sh            # needs sudo; ~20 s
    diskless/freebsd/build.sh status
    diskless/freebsd/build.sh tftp       # re-create/install only the patched loaders
    diskless/freebsd/build.sh export     # re-install only the NFS export

`build.sh` verifies `FreeBSD-15.1-RELEASE-amd64-disc1.iso` against the release
`CHECKSUM.SHA256-...` file, takes `usr/freebsd-dist/MANIFEST` out of that ISO and verifies
`base.txz` and `kernel.txz` against it, then:

1. ZFS dataset `vms/pxe-images/freebsd-15.1` mounted at `/srv/pxe-images/freebsd-15.1-diskless`
   (created if missing). A rebuild snapshots the old tree as `@pre-<stamp>`, wipes the
   contents, extracts base + kernel as root (GNU `tar -xpf --numeric-owner`), snapshots the
   untouched tree as `@pristine-<stamp>`, applies the configuration, snapshots `@built-<stamp>`
   (the newest 4 of each kind are kept). The inputs hash (txz sums, `overlay/`, `build.sh`,
   keys, password, settings) is stored in the ZFS property `pxe:inputs`; with unchanged inputs
   nothing is rewritten (`FORCE=1` overrides). It refuses to run while NFS clients have the
   root mounted (`showmount -a`; stale entries of dead clients count: `CLIENTS_OK=1`).
2. Configuration: `overlay/` + generated files (below) are put in `/conf/default/...`;
   `/conf/base/{etc,var}` is a replica of the original `/etc` and `/var`.
3. Loaders: `/boot/pxeboot` (BIOS) and `/boot/loader.efi` (UEFI) get the NFS root path
   `10.20.0.26:/srv/pxe-images/freebsd-15.1-diskless` written into libsa's 128-byte `/` slot
   (the same method as `prepare.d/freebsd.sh`; exactly one slot must be found). Kept in
   `/srv/pxe-images/tftp/freebsd/15.1_diskless/` and installed to
   `/srv/tftp/freebsd/15.1_diskless/{pxeboot,loader_pxe.efi}`.
4. NFS export `/etc/exports.d/freebsd-diskless.exports` (original `/etc/exports` backed up as
   `/etc/exports.bak-freebsd-diskless`): `ro,no_root_squash,insecure,no_subtree_check,fsid=15101`
   for `10.20.0.0/16`, then `exportfs -ra`. The tree is a single dataset (no nested
   datasets), so no `crossmnt` is needed; ZFS has no UUID, hence the fixed `fsid`.

Variables (environment or `build.conf`, not in git): `FBSD_VER`, `DOWNLOADS`, `DATASET`, `ROOT`,
`NFS_HOST`, `EXPORT_CLIENTS`, `EXPORT_FSID`, `TFTP_ROOT`, `TFTP_SUBDIR`, `SECRETS_DIR`,
`ADMIN_USER`, `ADMIN_UID`, `AUTHORIZED_KEYS`, `TZ_NAME`, `ROOT_LOGIN`
(`console-password` = root has the same password as the admin user, for `su`; `locked`).

> The loaders are patched per root path: rebuilding into the *same* dataset and path needs
> nothing else. `rsync --delete` of a new TFTP stage into `/srv/tftp` removes
> `freebsd/15.1_diskless/`; run `build.sh tftp` afterwards (or exclude that directory).

## What the tree contains (`overlay/`, generated)

| Where | What |
|---|---|
| `/boot/loader.conf` | `console="comconsole,efi,vidconsole"`, `comconsole_speed=115200`, `boot_multicons`, `boot_serial`, `autoboot_delay=3` |
| `/etc/diskless` | forces `rc.initdiskless` |
| `/conf/base/{etc,var}` + `md_size` | replica of `/etc` (20 MiB tmpfs), `/var` (128 MiB tmpfs; memory is only used when written) |
| `/conf/default/etc/rc.conf` | hostname from the DHCP host-name (kenv `dhcp.host-name`), else `freebsd-diskless`; `ifconfig_DEFAULT="DHCP"`; `sshd_enable`; `root_rw_mount=NO`; no entropy file |
| `/conf/default/etc/dhclient-enter-hooks` | dhclient must not re-apply the address of the NFS-root interface (see below) |
| `/conf/default/etc/fstab` | tmpfs `/tmp` (256 MiB) and `/home` (128 MiB) |
| `/conf/default/etc/ttys` | `ttyu0 "/usr/libexec/getty 3wire.115200" vt100 onifconsole secure` |
| `/conf/default/etc/ssh/` | `sshd_config` (no root, no passwords, keys from `/etc/ssh/authorized_keys/%u`), shared host keys, `authorized_keys/nick` |
| `/conf/default/etc/{master.passwd,passwd,group}` | user `nick` (uid 1001, `wheel`), password hash of the secret file; root gets the same hash (`ROOT_LOGIN`) |
| `/conf/default/etc/rc.d/diskless_users` | runs `pwd_mkdb` at boot (FreeBSD binary: cannot run at build time) and creates `/home/nick` |
| `/conf/default/etc/localtime`, `var/db/zoneinfo` | `Asia/Taipei` |

NICs: the GENERIC kernel has em/igb (Intel), re (Realtek), rl, vtnet built in; `kld_list` is empty.

**dhclient and the NFS root.** The kernel configures the boot NIC from the loader's DHCP lease.
`dhclient-script` (`ifconfig_DEFAULT="DHCP"`) re-adds the same address, which removes the
default route; with the NFS server off-link the next `exec` from the root hangs for good
(seen in QEMU on a routed test network). `dhclient-enter-hooks` therefore only writes
`/etc/resolv.conf` for that interface when the address is unchanged. Other NICs are handled
normally. The lease is still renewed by dhclient.

## Serial console (vmsrt: COM1/ttyS0, 115200 8N1)

* Loader (BIOS pxeboot and UEFI loader.efi) and kernel print to the serial port and the screen
  (`Dual Console: Serial Primary, Video Secondary`); the login prompt is on `ttyu0` and on
  `ttyv0` (video). From the host: `virsh console vmsrt` (leave with `Ctrl+]`).
* The loader passes `hw.uart.console` to the kernel; `onifconsole` starts the getty on ttyu0
  because the serial port is a console.

## Accounts and secrets (paths only)

    /srv/pxe-images/secrets/freebsd-nick-console-password   0600, random, plain text; hash baked
    /srv/pxe-images/secrets/ssh-host-freebsd/               0700: shared ssh_host_{ed25519,ecdsa,rsa}_key
    gen-secrets.sh [--rotate]                               idempotent; --rotate changes host keys

The NFS root contains the private host keys and the password hash (mode 0600 root-owned, but
the export uses `no_root_squash` for 10.20.0.0/16: any root on that network can read them).
Never export it more widely. `nick` logs in with the keys from `~nick/.ssh/authorized_keys`
on the build host; `su` needs the console password (there is no `sudo`/`doas` in the base system).

## Tests (QEMU)

    diskless/freebsd/qemu-test.sh setup           # tap fbtest0 10.98.0.1/24, test export (own subnet,
                                                  # own dnsmasq, own pid file: other PXE tests are not touched)
    diskless/freebsd/test-matrix.sh               # uefi|bios x virtio|e1000|rtl8139, serial login + verify-guest.sh
    diskless/freebsd/qemu-test.sh run uefi -n e1000 -d 120   # single run, screenshots + serial.log in /tmp
    diskless/freebsd/qemu-test.sh teardown

## Rollback

    sudo zfs list -t snapshot -r vms/pxe-images/freebsd-15.1
    sudo zfs rollback -r vms/pxe-images/freebsd-15.1@built-<stamp>      # or @pre-<stamp> (previous tree)
    sudo zfs clone vms/pxe-images/freebsd-15.1@pre-<stamp> vms/pxe-images/freebsd-15.1-old   # inspect without touching
    # remove everything: delete the menu entry, then
    sudo rm /etc/exports.d/freebsd-diskless.exports && sudo exportfs -ra
    sudo rm -r /srv/tftp/freebsd/15.1_diskless /srv/pxe-images/tftp
    sudo zfs destroy -r vms/pxe-images/freebsd-15.1

Roll back only while no client runs from the tree (stale NFS handles).

## Not in the base system

`sudo`, `doas`, `vim`, `bash`, ... come from packages. `pkg` is not bootstrapped (the root is
read-only and `/usr/local` does not exist). Options: a tmpfs `/usr/local` filled at boot, or a
second read-only NFS tree under `/usr/local` built with `pkg -r`/`pkg --rootdir` on a FreeBSD host.

## boot.ipxe menu entry

See `ipxe-menu-fragment.txt`.
