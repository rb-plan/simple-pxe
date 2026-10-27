#!/bin/sh
# mmdebstrap --customize-hook: runs once after the packages are installed.
#   $1 = root directory of the new system. Everything else comes from the environment
#   that build.sh exports (BUILD_ID, TZ_NAME, ...). In unshare mode this runs as the
#   namespace's "root" (a subuid of the calling user, NOT the calling user itself): it
#   cannot read the caller's private files, so build.sh feeds the secrets in through
#   mmdebstrap's copy-in hook (-> $root/tmp/inputs) and takes the results out with copy-out
#   (<- $root/export). No real root privileges are involved.
set -eu
root="$1"
c() { chroot "$root" "$@"; }
in="$root/tmp/inputs"

# files copied from the (unprivileged) overlay dir arrive owned by "nobody"
(cd "$OVERLAY_DIR" && find . -mindepth 1 | while read -r p; do chown -h 0:0 "$root/$p"; done)

# ---- time zone and locale (build variables TZ_NAME, LOCALE_NAME) --------------------
[ -e "$root/usr/share/zoneinfo/$TZ_NAME" ] || { echo "unknown time zone $TZ_NAME" >&2; exit 1; }
ln -sf "/usr/share/zoneinfo/$TZ_NAME" "$root/etc/localtime"
echo "$TZ_NAME" >"$root/etc/timezone"
for l in $LOCALE_NAME; do
    sed -i "s/^# *\($l \)/\1/" "$root/etc/locale.gen"
done
c locale-gen
echo "LANG=${LOCALE_NAME%% *}" >"$root/etc/default/locale"

# ---- identity: hostname comes from DHCP, machine-id is made at every boot ------------
rm -f "$root/etc/hostname"
cat >"$root/etc/hosts" <<HOSTS
127.0.0.1 localhost
::1       localhost ip6-localhost ip6-loopback
HOSTS
: >"$root/etc/machine-id"
mkdir -p "$root/var/lib/dbus"
ln -sf /etc/machine-id "$root/var/lib/dbus/machine-id"
cat >"$root/etc/fstab" <<'FSTAB'
# Intentionally empty: live-boot mounts the squashfs + a tmpfs overlay as /.
FSTAB
rm -f "$root/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"

cat >"$root/etc/diskless-release" <<REL
BUILD_ID=$BUILD_ID
SUITE=$SUITE
DEFAULT_HOSTNAME=$DEFAULT_HOSTNAME
TZ_NAME=$TZ_NAME
BUILD_MIRROR=$BUILD_MIRROR
REL
cat >"$root/etc/motd" <<MOTD

Debian $SUITE diskless, build $BUILD_ID
Everything outside this session lives in RAM and is gone at the next reboot.

MOTD

# ---- apt sources for the running system (not the build mirror) ------------------------
rm -f "$root/etc/apt/sources.list"
mkdir -p "$root/etc/apt/sources.list.d"
cat >"$root/etc/apt/sources.list.d/debian.sources" <<SRC
Types: deb
URIs: $RUNTIME_MIRROR
Suites: $SUITE ${SUITE}-updates
Components: $COMPONENTS
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $RUNTIME_SECURITY_MIRROR
Suites: ${SUITE}-security
Components: $COMPONENTS
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SRC

# ---- users ---------------------------------------------------------------------------
c passwd -l root >/dev/null
c useradd -m -u 1000 -s /bin/bash -G sudo "$ADMIN_USER"
printf '%s:%s\n' "$ADMIN_USER" "$(cat "$in/password.hash")" | c chpasswd -e
if [ -s "$in/authorized_keys" ]; then
    install -d -m 700 "$root/home/$ADMIN_USER/.ssh"
    install -m 600 "$in/authorized_keys" "$root/home/$ADMIN_USER/.ssh/authorized_keys"
    c chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
fi

# ---- one shared SSH host key set, never regenerated ---------------------------------------
# openssh-server's postinst made throw-away keys inside the chroot; replace all of them.
rm -f "$root"/etc/ssh/ssh_host_*
for t in ed25519 ecdsa rsa; do
    install -m 600 "$in/ssh-host/ssh_host_${t}_key" "$root/etc/ssh/ssh_host_${t}_key"
    install -m 644 "$in/ssh-host/ssh_host_${t}_key.pub" "$root/etc/ssh/ssh_host_${t}_key.pub"
done

# ---- services ---------------------------------------------------------------------------
c systemctl enable systemd-networkd.service systemd-resolved.service \
    systemd-timesyncd.service systemd-networkd-wait-online.service \
    diskless-hostname-fallback.service ssh.service
# systemd-firstboot would prompt on the console when machine-id is uninitialised
c systemctl mask systemd-firstboot.service

# ---- kernel + initrd go next to the squashfs, not into it -----------------------------------
mkdir -p "$root/export"
set -- "$root"/boot/vmlinuz-*
[ "$#" -eq 1 ] && [ -e "$1" ] || { echo "expected exactly one kernel in /boot" >&2; exit 1; }
kver="${1##*/vmlinuz-}"
[ -s "$root/boot/initrd.img-$kver" ] || { echo "no initrd for $kver" >&2; exit 1; }
cp "$1" "$root/export/vmlinuz"
cp "$root/boot/initrd.img-$kver" "$root/export/initrd.img"
echo "$kver" >"$root/export/KERNEL_VERSION"
c dpkg-query -W -f='${Package} ${Version}\n' >"$root/export/packages.txt"
rm -f "$root"/boot/vmlinuz-* "$root"/boot/initrd.img-* "$root"/boot/System.map-* "$root"/boot/config-*
rm -f "$root/vmlinuz" "$root/initrd.img" "$root/vmlinuz.old" "$root/initrd.img.old"

