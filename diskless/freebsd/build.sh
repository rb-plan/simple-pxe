#!/bin/bash
# Build the diskless FreeBSD 15.1 (amd64) NFS root from the release base.txz + kernel.txz,
# patch the PXE loaders and publish them. Needs sudo (extract as root, ZFS, TFTP, exports).
#
#   diskless/freebsd/build.sh               # = build: verify, (re)build tree, loaders, export
#   diskless/freebsd/build.sh tftp          # only re-create + install the patched loaders
#   diskless/freebsd/build.sh export        # only (re)install the NFS export
#   diskless/freebsd/build.sh status        # dataset, snapshots, export, TFTP files
#
# build is idempotent: when the inputs (checksummed txz files, overlay, keys, password,
# settings) are the same as for the tree that is already there, nothing is rewritten.
# FORCE=1 rebuilds anyway. A rebuild first takes the ZFS snapshot @pre-<stamp> of the old
# tree (rollback point), wipes the dataset contents, extracts again, snapshots the
# untouched tree as @pristine-<stamp> and the finished one as @built-<stamp>.
# Packages (packages.txt, see README) are resolved and downloaded by pkg-fetch.py and unpacked
# into /usr/local of the tree; the list and the resolved versions are part of the inputs.
# It refuses to run while NFS clients have the root mounted (CLIENTS_OK=1 overrides).

set -euo pipefail

HERE="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "${HERE}/build.conf" ]] && source "${HERE}/build.conf"

: "${FBSD_VER:=15.1}"
: "${DOWNLOADS:=/srv/pxe-data/downloads/freebsd/${FBSD_VER}}"
: "${DATASET:=vms/pxe-images/freebsd-${FBSD_VER}}"
: "${ROOT:=/srv/pxe-images/freebsd-${FBSD_VER}-diskless}"
: "${NFS_HOST:=10.20.0.26}"
: "${EXPORT_CLIENTS:=10.20.0.0/16}"
: "${EXPORT_FSID:=15101}"
: "${EXPORT_FILE:=/etc/exports.d/freebsd-diskless.exports}"
: "${TFTP_ROOT:=/srv/tftp}"
: "${TFTP_SUBDIR:=freebsd/${FBSD_VER}_diskless}"
: "${LOADER_STAGE:=/srv/pxe-images/tftp/${TFTP_SUBDIR}}"
: "${SECRETS_DIR:=/srv/pxe-images/secrets}"
: "${ADMIN_USER:=nick}"
: "${ADMIN_UID:=1026}"
: "${ADMIN_GID:=100}"
: "${ADMIN_GROUP:=users}"
: "${PKG_LIST:=${HERE}/packages.txt}"
: "${PKG_BRANCH:=quarterly}"          # quarterly (matches /etc/pkg/FreeBSD.conf of the release) | latest
: "${PKG_MIRRORS:=https://mirrors.aliyun.com/freebsd-pkg https://pkg.freebsd.org}"   # tried in order
: "${PKG_CACHE:=/srv/pxe-images/.cache/freebsd-pkg}"
: "${PKG_REFRESH:=}"                  # 1 = fetch the repository catalog again (newer versions)
: "${AUTHORIZED_KEYS:=${HOME}/.ssh/authorized_keys}"
: "${TZ_NAME:=Asia/Taipei}"
: "${ROOT_LOGIN:=console-password}"   # console-password | locked (root has no usable password)
: "${KEEP_SNAPSHOTS:=4}"
export SECRETS_DIR ADMIN_USER

KEYDIR="${SECRETS_DIR}/ssh-host-freebsd"
PWFILE="${SECRETS_DIR}/freebsd-${ADMIN_USER}-console-password"
ROOTPWFILE="${SECRETS_DIR}/freebsd-root-console-password"
NFS_ROOTPATH="${NFS_HOST}:${ROOT}"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORKDIR="/srv/pxe-images/.work"
SELF_LOCK="${WORKDIR}/freebsd-diskless.lock"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

verify_inputs() {
	local sums="${DOWNLOADS}/CHECKSUM.SHA256-FreeBSD-${FBSD_VER}-RELEASE-amd64"
	local iso="${DOWNLOADS}/FreeBSD-${FBSD_VER}-RELEASE-amd64-disc1.iso"
	local f want got
	for f in base.txz kernel.txz "${iso##*/}" "${sums##*/}"; do
		[[ -s "${DOWNLOADS}/${f}" ]] || die "missing ${DOWNLOADS}/${f}"
	done
	# The release CHECKSUM file covers the ISOs only; the ISO's own usr/freebsd-dist/MANIFEST
	# carries the checksums of base.txz / kernel.txz, so the chain is
	# CHECKSUM -> disc1.iso -> MANIFEST -> {base,kernel}.txz.
	want="$(sed -nE "s/^SHA256 \(${iso##*/}\) = ([0-9a-f]{64})$/\1/p" "${sums}")"
	[[ -n "${want}" ]] || die "no checksum for ${iso##*/} in ${sums}"
	got="$(sha256sum "${iso}" | cut -d' ' -f1)"
	[[ "${got}" == "${want}" ]] || die "disc1.iso checksum mismatch"
	MANIFEST="$(bsdtar -xOf "${iso}" usr/freebsd-dist/MANIFEST)"
	for f in base.txz kernel.txz; do
		want="$(awk -v f="${f}" '$1 == f {print $2}' <<<"${MANIFEST}")"
		[[ -n "${want}" ]] || die "${f} not in the ISO MANIFEST"
		got="$(sha256sum "${DOWNLOADS}/${f}" | cut -d' ' -f1)"
		[[ "${got}" == "${want}" ]] || die "${f} checksum mismatch"
		eval "SUM_${f%.txz}=${got}"
	done
	log "checksums OK (disc1.iso -> MANIFEST -> base.txz, kernel.txz)"
}

authorized_keys_lines() {
	local line
	[[ -r "${AUTHORIZED_KEYS}" ]] || die "no ${AUTHORIZED_KEYS}"
	while IFS= read -r line; do
		[[ -z "${line}" || "${line}" == \#* ]] && continue
		if ssh-keygen -l -f /dev/stdin <<<"${line}" >/dev/null 2>&1; then
			echo "${line}"
		fi
	done <"${AUTHORIZED_KEYS}"
}

inputs_hash() {
	{
		echo "${SUM_base} ${SUM_kernel} ${TZ_NAME} ${ROOT_LOGIN} ${ADMIN_USER} ${ADMIN_UID} ${ADMIN_GID} ${ADMIN_GROUP} ${NFS_ROOTPATH}"
		sha256sum "${PKG_LIST}" "${HERE}/pkg-fetch.py"
		cut -d' ' -f1-3 "${PKG_RESOLVED}"
		(cd "${HERE}/overlay" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
		sha256sum "${HERE}/build.sh"
		authorized_keys_lines | sha256sum
		sha256sum "${PWFILE}" "${ROOTPWFILE}" "${KEYDIR}"/ssh_host_*_key
	} | sha256sum | cut -d' ' -f1
}

# Resolve + download the packages (cached, signature and checksum verified), see pkg-fetch.py.
# The pkg signing key comes from the checksum-verified base.txz, not from the tree.
resolve_packages() {
	local keys abi="FreeBSD:${FBSD_VER%%.*}:amd64"
	PKG_RESOLVED="${WORKDIR}/freebsd-packages.resolved"
	keys="$(mktemp -d "${WORKDIR}/freebsd-pkgkeys.XXXXXX")"
	bsdtar -xf "${DOWNLOADS}/base.txz" -C "${keys}" ./usr/share/keys/pkg/trusted
	"${HERE}/pkg-fetch.py" --wanted "${PKG_LIST}" --cache "${PKG_CACHE}" --keys "${keys}/usr/share/keys/pkg/trusted" \
		--out "${PKG_RESOLVED}" --abi "${abi}" --branch "${PKG_BRANCH}" --mirrors "${PKG_MIRRORS}" \
		${PKG_REFRESH:+--refresh} || die "package resolution failed"
	rm -rf "${keys}"
}

install_packages() {
	local name ver sum file n=0
	while read -r name ver sum file; do
		sudo tar --zstd -xpf "${file}" -C "${ROOT}" --no-same-owner --anchored \
			--exclude='+MANIFEST' --exclude='+COMPACT_MANIFEST' 2> >(grep -v "Removing leading" >&2 || true)
		n=$((n + 1))
	done <"${PKG_RESOLVED}"
	# what pkg(8) does with *.sample config files and the e2fsprogs install script
	sudo find "${ROOT}/usr/local/etc" -name '*.sample' -type f | while read -r f; do
		[[ -e "${f%.sample}" ]] || sudo cp -p "${f}" "${f%.sample}"
	done
	if [[ -e "${ROOT}/usr/local/etc/mke2fs.conf.dist" && ! -e "${ROOT}/usr/local/etc/mke2fs.conf" ]]; then
		sudo cp -p "${ROOT}/usr/local/etc/mke2fs.conf.dist" "${ROOT}/usr/local/etc/mke2fs.conf"
	fi
	log "${n} packages unpacked into ${ROOT}/usr/local ($(sudo du -sh "${ROOT}/usr/local" | cut -f1))"
}

clients_mounted() {
	showmount -a --no-headers 10.20.0.26 2>/dev/null | grep -F ":${ROOT}" || true
}

# 128-byte "/" rootpath slot of libsa's NFS code; the NFS root path is written into it.
patch_nfs_root() {
	local src="$1" dst="$2" root="$3" loc
	(( ${#root} < 127 )) || die "root path too long for the loader slot"
	mapfile -t loc < <(grep -obUaP "\x2f\x00{127}" "${src}" | cut -d: -f1)
	(( ${#loc[@]} == 1 )) || die "${src}: expected exactly one rootpath slot, found ${#loc[@]}"
	[[ "${src}" == "${dst}" ]] || install -m644 "${src}" "${dst}"
	printf '%s\x00' "${root}" | dd of="${dst}" bs=1 seek="${loc[0]}" conv=notrunc status=none
	grep -qaF "${root}" "${dst}" || die "patch of ${dst} failed"
}

do_tftp() {
	[[ -s "${ROOT}/boot/pxeboot" ]] || die "no tree at ${ROOT}; run build first"
	mkdir -p "${LOADER_STAGE}"
	sudo cat "${ROOT}/boot/pxeboot" >"${LOADER_STAGE}/pxeboot.orig"
	sudo cat "${ROOT}/boot/loader.efi" >"${LOADER_STAGE}/loader.efi.orig"
	patch_nfs_root "${LOADER_STAGE}/pxeboot.orig" "${LOADER_STAGE}/pxeboot" "${NFS_ROOTPATH}"
	patch_nfs_root "${LOADER_STAGE}/loader.efi.orig" "${LOADER_STAGE}/loader_pxe.efi" "${NFS_ROOTPATH}"
	rm -f "${LOADER_STAGE}"/*.orig
	sudo mkdir -p "${TFTP_ROOT}/${TFTP_SUBDIR}"
	sudo rsync -a --chown=root:root --chmod=D755,F644 "${LOADER_STAGE}/" "${TFTP_ROOT}/${TFTP_SUBDIR}/"
	log "loaders (rootpath ${NFS_ROOTPATH}) in ${TFTP_ROOT}/${TFTP_SUBDIR}/"
	ls -l "${TFTP_ROOT}/${TFTP_SUBDIR}/"
}

do_export() {
	local line="${ROOT} ${EXPORT_CLIENTS}(ro,no_root_squash,insecure,no_subtree_check,fsid=${EXPORT_FSID})"
	[[ -e /etc/exports.bak-freebsd-diskless ]] || sudo cp -p /etc/exports /etc/exports.bak-freebsd-diskless
	sudo mkdir -p "$(dirname "${EXPORT_FILE}")"
	printf '# simple-pxe diskless FreeBSD %s root (ZFS %s), read-only.\n# no_root_squash: root-owned files; insecure: loader NFS client uses ports >1023;\n# fsid: ZFS has no UUID. No crossmnt: the tree is one dataset, no nested ones.\n%s\n' \
		"${FBSD_VER}" "${DATASET}" "${line}" | sudo tee "${EXPORT_FILE}" >/dev/null
	sudo exportfs -ra
	sudo exportfs -v | grep -A1 -F "${ROOT}" || die "export not active"
}

stage_overlay() {
	local S="$1" pw hash roothash keyfile t f
	pw="$(<"${PWFILE}")"
	[[ -n "${pw}" ]] || die "${PWFILE} is empty"
	hash="$(openssl passwd -6 -stdin <<<"${pw}")"
	pw="$(<"${ROOTPWFILE}")"
	[[ -n "${pw}" ]] || die "${ROOTPWFILE} is empty"
	roothash="$(openssl passwd -6 -stdin <<<"${pw}")"
	unset pw

	mkdir -p "${S}/boot" "${S}/etc" "${S}/home" "${S}/conf/base/etc" "${S}/conf/base/var" \
		"${S}/conf/default/etc/ssh/authorized_keys" "${S}/conf/default/etc/rc.d" "${S}/conf/default/var/db"
	cp -a "${HERE}/overlay/." "${S}/"
	grep -q "^Match User ${ADMIN_USER}\$" "${S}/conf/default/etc/ssh/sshd_config" \
		|| die "sshd_config lacks 'Match User ${ADMIN_USER}' (password login)"
	chmod 755 "${S}/conf/default/etc/rc.d/diskless_users"
	: >"${S}/etc/diskless"
	mkdir -p "${S}/usr/local/share/diskless"
	cut -d' ' -f1,2 "${PKG_RESOLVED}" >"${S}/usr/local/share/diskless/packages.txt"

	# memory filesystem sizes in 512-byte sectors: /etc 20 MiB, /var 128 MiB (tmpfs: RAM is
	# only used for what is written)
	echo 40960 >"${S}/conf/base/etc/md_size"
	echo 262144 >"${S}/conf/base/var/md_size"

	# time zone: /etc/localtime copy + /var/db/zoneinfo (what tzsetup(8) writes)
	sudo cat "${ROOT}/usr/share/zoneinfo/${TZ_NAME}" >"${S}/conf/default/etc/localtime" \
		|| die "no zoneinfo ${TZ_NAME}"
	echo "${TZ_NAME}" >"${S}/conf/default/var/db/zoneinfo"

	# accounts. pwd.db/spwd.db are rebuilt at boot by rc.d/diskless_users.
	local mp="${S}/conf/default/etc/master.passwd"
	sudo cat "${ROOT}/etc/master.passwd" >"${mp}"
	if [[ "${ROOT_LOGIN}" == console-password ]]; then
		sed -i "s|^root:[^:]*:|root:${roothash}:|" "${mp}"
	else
		sed -i 's|^root:[^:]*:|root:*:|' "${mp}"
	fi
	grep -q '^root:[^:]\+:' "${mp}" || die "root password field is empty"
	echo "${ADMIN_USER}:${hash}:${ADMIN_UID}:${ADMIN_GID}::0:0:${ADMIN_USER} (diskless admin):/home/${ADMIN_USER}:/bin/sh" >>"${mp}"
	chmod 600 "${mp}"
	awk -F: 'BEGIN{OFS=":"} /^#/ {print; next} NF==10 {$2="*"; print}' "${mp}" >"${S}/conf/default/etc/passwd"
	sudo cat "${ROOT}/etc/group" >"${S}/conf/default/etc/group"
	sed -i "s|^wheel:\*:0:root\$|wheel:*:0:root,${ADMIN_USER}|" "${S}/conf/default/etc/group"
	grep -q "^wheel:\*:0:root,${ADMIN_USER}\$" "${S}/conf/default/etc/group" || die "wheel line not as expected"
	sudo cat "${ROOT}/etc/group" | awk -F: -v g="${ADMIN_GROUP}" -v id="${ADMIN_GID}" '$1 == g || $3 == id {exit 1}' \
		|| die "group ${ADMIN_GROUP}/gid ${ADMIN_GID} already exists in the base system"
	echo "${ADMIN_GROUP}:*:${ADMIN_GID}:" >>"${S}/conf/default/etc/group"
	unset hash roothash
	authorized_keys_lines >"${S}/conf/default/etc/ssh/authorized_keys/${ADMIN_USER}"
	[[ -s "${S}/conf/default/etc/ssh/authorized_keys/${ADMIN_USER}" ]] || die "no usable public keys in ${AUTHORIZED_KEYS}"
	chmod 644 "${S}/conf/default/etc/ssh/authorized_keys/${ADMIN_USER}"

	# shared host keys
	for t in ed25519 ecdsa rsa; do
		keyfile="${KEYDIR}/ssh_host_${t}_key"
		[[ -s "${keyfile}" ]] || die "missing ${keyfile}"
		install -m600 "${keyfile}" "${S}/conf/default/etc/ssh/ssh_host_${t}_key"
		install -m644 "${keyfile}.pub" "${S}/conf/default/etc/ssh/ssh_host_${t}_key.pub"
	done

	# serial console: getty on COM1, 115200 8N1 (only when the serial port is a console)
	sudo cat "${ROOT}/etc/ttys" >"${S}/conf/default/etc/ttys"
	sed -i -E 's|^ttyu0[[:space:]].*|ttyu0\t"/usr/libexec/getty 3wire.115200"\tvt100\tonifconsole secure|' "${S}/conf/default/etc/ttys"
	grep -q '^ttyu0.*3wire.115200' "${S}/conf/default/etc/ttys" || die "ttys edit failed"
	chmod 644 "${S}/conf/default/etc/ttys"
}

verify_tree() {
	# the package archives carry uid/gid 65534 with the names root/wheel: everything must be 0:0
	[[ -z "$(sudo find "${ROOT}/usr/local" ! -uid 0 -print -quit)" ]] || die "files in /usr/local not owned by uid 0"
	sudo test -u "${ROOT}/usr/local/bin/doas" || die "doas is not setuid root in the tree"
	[[ "$(sudo cat "${ROOT}/usr/local/etc/doas.conf")" == *"permit nopass :wheel"* ]] || die "doas.conf missing"
	sudo grep -q "^${ADMIN_USER}:\\\$6\\\$[^:]*:${ADMIN_UID}:${ADMIN_GID}:" "${ROOT}/conf/default/etc/master.passwd" \
		|| die "master.passwd: unexpected ${ADMIN_USER} entry"
	sudo grep -q "^${ADMIN_GROUP}:\\*:${ADMIN_GID}:" "${ROOT}/conf/default/etc/group" || die "group file lacks ${ADMIN_GROUP}"
	sudo test -s "${ROOT}/usr/local/share/diskless/packages.txt" || die "package list missing in the tree"
}

prune_snapshots() {
	local kind snaps n
	for kind in pre pristine built; do
		mapfile -t snaps < <(zfs list -H -t snapshot -o name -s creation -d 1 "${DATASET}" | grep "@${kind}-" || true)
		n=$(( ${#snaps[@]} - KEEP_SNAPSHOTS ))
		for ((i = 0; i < n; i++)); do sudo zfs destroy "${snaps[i]}"; done
	done
}

do_build() {
	verify_inputs
	"${HERE}/gen-secrets.sh" >/dev/null
	mkdir -p "$(dirname "${SELF_LOCK}")"
	exec 9>"${SELF_LOCK}"
	flock -n 9 || die "another build is running"

	local want have
	resolve_packages
	want="$(inputs_hash)"
	if zfs list -H "${DATASET}" >/dev/null 2>&1; then
		have="$(zfs get -H -o value pxe:inputs "${DATASET}")"
		if [[ "${have}" == "${want}" && -z "${FORCE:-}" && -s "${ROOT}/boot/kernel/kernel" ]]; then
			log "tree is up to date (inputs ${want:0:12}); FORCE=1 to rebuild"
			do_tftp
			do_export
			return 0
		fi
		# if [[ -z "${CLIENTS_OK:-}" && -n "$(clients_mounted)" ]]; then
		# 	clients_mounted >&2
		# 	die "NFS clients have ${ROOT} mounted; stop them or CLIENTS_OK=1"
		# fi
		if [[ -s "${ROOT}/boot/kernel/kernel" ]]; then
			sudo zfs snapshot "${DATASET}@pre-${STAMP}"
			log "old tree kept as ${DATASET}@pre-${STAMP}"
		fi
		sudo find "${ROOT}" -mindepth 1 -delete
	else
		sudo zfs create -o mountpoint="${ROOT}" "${DATASET}"
	fi

	log "extracting base.txz + kernel.txz into ${ROOT}"
	for f in base kernel; do
		sudo tar -xpf "${DOWNLOADS}/${f}.txz" -C "${ROOT}" --numeric-owner 2> >(grep -v "SCHILY.fflags" >&2 || true)
	done
	[[ -s "${ROOT}/boot/kernel/kernel" && -s "${ROOT}/etc/rc.initdiskless" ]] || die "extraction incomplete"
	sudo zfs snapshot "${DATASET}@pristine-${STAMP}"

	log "packages (${PKG_LIST##*/})"
	install_packages

	log "diskless configuration"
	S="$(mktemp -d "/srv/pxe-images/.work/freebsd-stage.XXXXXX")"
	trap '[[ -z "${S:-}" ]] || rm -rf "${S}"' EXIT
	chmod 700 "${S}"
	stage_overlay "${S}"
	# /conf/base: replica of the original /etc and /var (rc.initdiskless copies it into the
	# memory filesystems), /conf/default: our overrides on top (see diskless(8)).
	sudo mkdir -p "${ROOT}/conf/base"
	sudo cp -a "${ROOT}/etc" "${ROOT}/var" "${ROOT}/conf/base/"
	# (the staging top directory itself is not part of the archive, its mode must not
	# be applied to the root of the tree)
	(cd "${S}" && find . -mindepth 1 -print0 \
		| sudo tar --null --no-recursion -T - --owner=0 --group=0 --numeric-owner -cf -) \
		| sudo tar -C "${ROOT}" -xpf - --numeric-owner
	sudo chmod 755 "${ROOT}/home"
	rm -rf "${S}"; trap - EXIT

	verify_tree
	sudo zfs set "pxe:inputs=${want}" "${DATASET}"
	sudo zfs snapshot "${DATASET}@built-${STAMP}"
	prune_snapshots
	do_tftp
	do_export
	log "done: ${ROOT} (inputs ${want:0:12}); snapshots:"
	zfs list -t snapshot -o name,creation -d 1 "${DATASET}"
}

do_status() {
	zfs list -o name,mountpoint,used,refer "${DATASET}" || true
	zfs list -t snapshot -o name,creation -d 1 "${DATASET}" 2>/dev/null || true
	zfs get -H -o value pxe:inputs "${DATASET}" 2>/dev/null || true
	sudo exportfs -v | grep -A1 -F "${ROOT}" || echo "not exported"
	ls -l "${TFTP_ROOT}/${TFTP_SUBDIR}/" 2>&1
	clients_mounted
}

case "${1:-build}" in
build) do_build ;;
tftp) do_tftp ;;
export) do_export ;;
status) do_status ;;
*) sed -n '2,/^set -e/p' "$0" | sed '$d' >&2; exit 2 ;;
esac
