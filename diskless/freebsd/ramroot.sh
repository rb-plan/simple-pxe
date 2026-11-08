#!/bin/sh
# init_script. The loader still boots an NFS root (it has to, to read the kernel).
# This copies that root's archive into a memory disk and reroots onto it, so the
# running system no longer depends on NFS.
#
# init(8) runs this script twice more if init_script stays set:
#   1. after it re-execs itself from /dev/reroot/init -r, while the NFS root is
#      still mounted (reroot phase two has not run yet);
#   2. after the new root's /sbin/init starts.
# The first of those must exit 0 without touching the memory disk. A non-zero
# exit, or another reboot -r, makes init drop phase two and unmount the tmpfs
# that holds its own binary. Clearing init_script avoids both extra runs.
#
# RAM: the memory disk is sized in /ramroot.bytes (about 1.2x the tree). A client
# needs roughly that much free RAM plus the kernel, so 4 GB is the practical minimum.

PATH=/sbin:/bin:/usr/sbin:/usr/bin
say() { printf 'ramroot: %s\n' "$*" >/dev/console; }

case "$(ps -p 1 -o args= 2>/dev/null)" in
/dev/reroot/init*)
	exit 0
	;;
esac

rootdev=$(mount -p | awk '$2 == "/" { print $1; exit }')
if [ "${rootdev}" = /dev/md0 ]; then
	exit 0
fi

say "NFS root ${rootdev}; loading the system into memory"

bytes=$(cat /ramroot.bytes) || exit 1
case "${bytes}" in
''|*[!0-9]*) say "bad /ramroot.bytes"; exit 1 ;;
esac
# mdconfig without a suffix treats the number as sectors and rejects this size.
# Round up to whole mebibytes and pass an explicit suffix.
mib=$(((bytes + 1048575) / 1048576))

mdconfig -d -u 0 >/dev/null 2>&1 || true
mdconfig -a -t swap -u 0 -s "${mib}m" || exit 1
newfs -U -O 2 -i 8192 /dev/md0 >/dev/null || exit 1
mkdir -p /mnt
mount -o noatime /dev/md0 /mnt || exit 1
say "extracting /ramroot.tar.zst"
/usr/bin/tar -xpf /ramroot.tar.zst -C /mnt || { umount /mnt; exit 1; }
umount /mnt || exit 1

# Drop the script before the re-exec, so the phase-two init mounts the memory
# disk instead of running this again. reboot -r returns as soon as init has
# accepted the request; init then kills this process.
kenv -u init_script >/dev/null 2>&1 || true
kenv vfs.root.mountfrom="ufs:/dev/md0"
kenv vfs.root.mountfrom.options="rw"
say "reroot onto /dev/md0 (${mib}M)"
reboot -r
sleep 60
exit 0
