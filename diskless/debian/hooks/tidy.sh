#!/bin/sh
# mmdebstrap --customize-hook, last one: runs after the secrets/export staging was
# copied in/out. Removes everything that must not end up in the squashfs. (mmdebstrap
# itself empties /var/lib/apt/lists afterwards and needs the files it keeps in /tmp.)
set -eu
root="$1"
chroot "$root" apt-get clean
rm -rf "$root"/tmp/inputs "$root"/export
rm -rf "$root"/var/cache/ldconfig/aux-cache \
    "$root"/var/log/apt "$root"/var/log/dpkg.log "$root"/var/log/alternatives.log \
    "$root"/var/log/bootstrap.log "$root"/var/log/faillog "$root"/var/log/lastlog
