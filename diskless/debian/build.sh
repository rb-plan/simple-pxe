#!/bin/bash
# Build the diskless Debian image (squashfs + kernel + initrd) for live-boot.
#
#   diskless/debian/build.sh [build]     build a new version, verify, switch "current"
#   diskless/debian/build.sh verify DIR  re-run the verification on an existing build
#   diskless/debian/build.sh prune       drop old builds (keeps KEEP, never the current one)
#
# Output: ${OUT_ROOT}/<YYYYMMDD-HHMM>/{filesystem.squashfs,vmlinuz,initrd.img,SHA256SUMS,...}
# and the symlink ${OUT_ROOT}/current -> <YYYYMMDD-HHMM>, switched atomically (rename) only
# after the new build passed verification.
#
# Everything is a variable with a default; override in the environment or in
# diskless/debian/build.conf (shell syntax, not in git). See README.md.
#
# Privileges: none. mmdebstrap runs with --mode=unshare (a user namespace mapped through
# /etc/subuid, no root, no sudo, nothing outside OUT_ROOT/WORK_ROOT/the apt cache is
# written). If user namespaces are unavailable use MODE=fakeroot.

set -euo pipefail

HERE="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "${HERE}/build.conf" ]] && source "${HERE}/build.conf"

: "${SUITE:=trixie}"
: "${ARCH:=amd64}"
# Mirror used for the BUILD. Upstream for now; switch to the hub mirror once its first
# sync is complete:  MIRROR=http://10.20.0.26/debian
: "${MIRROR:=http://mirrors.ustc.edu.cn/debian}"
# Mirrors written into the image's /etc/apt/sources.list.d (what apt on a booted client uses).
: "${RUNTIME_MIRROR:=http://10.20.0.26/debian}"
: "${RUNTIME_SECURITY_MIRROR:=http://10.20.0.26/debian-security}"
: "${COMPONENTS:=main non-free-firmware}"
: "${TZ_NAME:=Asia/Taipei}"
: "${LOCALE_NAME:=en_US.UTF-8 UTF-8}"
: "${DEFAULT_HOSTNAME:=trixie-diskless}"
: "${ADMIN_USER:=nick}"
: "${AUTHORIZED_KEYS:=${HOME}/.ssh/authorized_keys}"
: "${OUT_ROOT:=/srv/pxe-images/debian-${SUITE}-diskless}"
: "${SECRETS_DIR:=/srv/pxe-images/secrets}"
: "${WORK_ROOT:=/srv/pxe-images/.work}"
: "${APT_CACHE:=/srv/pxe-images/.cache/apt-archives-${SUITE}}"
: "${KEEP:=3}"
: "${MODE:=unshare}"
# zstd: fast to decompress on slow/old clients and in the kernel (CONFIG_SQUASHFS_ZSTD);
# xz is ~10-15% smaller but several times slower to decompress. See README.md.
: "${SQUASHFS_COMP:=zstd}"
: "${SQUASHFS_LEVEL:=19}"
: "${SQUASHFS_BLOCK:=256K}"
: "${SQUASHFS_PROCESSORS:=4}"
: "${KEEP_WORK:=0}"

PACKAGES_FILE="${PACKAGES_FILE:-${HERE}/packages.list}"
BUILD_ID="${BUILD_ID:-$(date +%Y%m%d-%H%M)}"

die() { echo "build.sh: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*"; }

# --- verify -----------------------------------------------------------------------------
verify_build() {
	local dir="$1" rc=0 tmp t f
	[[ -d "${dir}" ]] || die "no such build dir: ${dir}"
	log "verify ${dir}"
	(cd "${dir}" && sha256sum --quiet -c SHA256SUMS) || die "SHA256SUMS mismatch"
	[[ -s "${dir}/vmlinuz" && -s "${dir}/initrd.img" ]] || die "kernel or initrd missing"
	unsquashfs -s "${dir}/filesystem.squashfs" >/dev/null || die "squashfs superblock unreadable"

	# the shared host keys must be exactly the stored ones, and nothing else
	for t in ed25519 ecdsa rsa; do
		f="ssh_host_${t}_key.pub"
		unsquashfs -cat "${dir}/filesystem.squashfs" "etc/ssh/${f}" | cmp -s - "${SECRETS_DIR}/ssh-host/${f}" \
			|| die "host key ${t} in the image differs from ${SECRETS_DIR}/ssh-host"
	done
	tmp="$(unsquashfs -l "${dir}/filesystem.squashfs" | grep -c 'etc/ssh/ssh_host_.*_key$' || true)"
	[[ "${tmp}" == 3 ]] || die "unexpected number of host private keys in the image: ${tmp}"
	unsquashfs -cat "${dir}/filesystem.squashfs" etc/shadow | grep -q "^${ADMIN_USER}:\\\$" \
		|| die "no password hash for ${ADMIN_USER} in the image"
	unsquashfs -cat "${dir}/filesystem.squashfs" etc/shadow | grep -q '^root:[!*]' \
		|| die "root is not locked"
	unsquashfs -cat "${dir}/filesystem.squashfs" etc/machine-id | cmp -s - /dev/null \
		|| die "/etc/machine-id is not empty"
	unsquashfs -ll "${dir}/filesystem.squashfs" etc/localtime | grep -q "zoneinfo/${TZ_NAME}" \
		|| die "time zone is not ${TZ_NAME}"
	unsquashfs -ll "${dir}/filesystem.squashfs" etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service \
		| grep -q 'serial-getty@ttyS0.service' || die "serial-getty@ttyS0 is not enabled"
	unsquashfs -cat "${dir}/filesystem.squashfs" etc/systemd/system/serial-getty@ttyS0.service.d/10-diskless.conf \
		| grep -q '115200 - ' || die "serial-getty@ttyS0 drop-in (115200) is missing"

	# initrd must contain live-boot and the NIC drivers + firmware we promise
	tmp="$(mktemp)"
	if command -v lsinitramfs >/dev/null; then
		lsinitramfs "${dir}/initrd.img" >"${tmp}"
	else
		zstd -dc "${dir}/initrd.img" 2>/dev/null | cpio -it >"${tmp}" 2>/dev/null || true
	fi
	for t in 'scripts/live' 'r8169' 'e1000e' 'e1000\.ko' '8139' 'virtio_net' 'squashfs' 'overlay' 'rtl_nic/'; do
		grep -q -- "${t}" "${tmp}" || { rm -f "${tmp}"; die "initrd lacks ${t}"; }
	done
	rm -f "${tmp}"
	log "verify OK"
	return "${rc}"
}

prune_builds() {
	local cur="" d n=0
	[[ -L "${OUT_ROOT}/current" ]] && cur="$(readlink "${OUT_ROOT}/current")"
	while read -r d; do
		n=$((n + 1))
		(( n <= KEEP )) && continue
		[[ "${d}" == "${cur}" ]] && continue
		[[ "${d}" =~ ^[0-9]{8}-[0-9]{4}$ ]] || continue
		log "prune ${OUT_ROOT}/${d}"
		rm -rf -- "${OUT_ROOT:?}/${d}"
	done < <(find "${OUT_ROOT}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
		-regex '.*/[0-9]{8}-[0-9]{4}' -printf '%f\n' | sort -r)
}

# --- main -----------------------------------------------------------------------------------
action="${1:-build}"
case "${action}" in
verify) verify_build "$(readlink -f "${2:?usage: build.sh verify DIR}")"; exit 0 ;;
prune) prune_builds; exit 0 ;;
build) ;;
*) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

[[ "$(id -u)" != 0 ]] || die "do not run as root (mode ${MODE} does not need it); use MODE=root only on purpose"
for tool in mmdebstrap mksquashfs unsquashfs sha256sum ssh-keygen openssl flock; do
	command -v "${tool}" >/dev/null || die "missing tool: ${tool}"
done
[[ -s "${PACKAGES_FILE}" ]] || die "no package list: ${PACKAGES_FILE}"
[[ -s "${SECRETS_DIR}/ssh-host/ssh_host_ed25519_key" && -s "${SECRETS_DIR}/${ADMIN_USER}-console-password" ]] \
	|| "${HERE}/gen-secrets.sh" >/dev/null
SSH_HOST_KEY_DIR="${SECRETS_DIR}/ssh-host"
[[ "$(stat -c %a "${SECRETS_DIR}")" == 700 ]] || die "${SECRETS_DIR} must be mode 0700"

mkdir -p "${OUT_ROOT}" "${WORK_ROOT}" "${APT_CACHE}"
exec 9>"${WORK_ROOT}/.build-${SUITE}.lock"
flock -n 9 || die "another build is running"

FINAL="${OUT_ROOT}/${BUILD_ID}"
[[ ! -e "${FINAL}" ]] || die "${FINAL} already exists (builds are per minute; wait or set BUILD_ID)"
WORK="${WORK_ROOT}/${BUILD_ID}"
STAGE="${OUT_ROOT}/.building-${BUILD_ID}"
cleanup() {
	[[ "${KEEP_WORK}" == 1 ]] || rm -rf -- "${WORK}"
	[[ -d "${STAGE}" ]] && rm -rf -- "${STAGE}"
	true
}
trap cleanup EXIT
rm -rf -- "${WORK}" "${STAGE}"
mkdir -p "${WORK}/tmp" "${STAGE}"
export TMPDIR="${WORK}/tmp"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"
export SOURCE_DATE_EPOCH

# --- inputs: password hash, cleaned authorized_keys, host keys ----------------------------------
# Staged in a private dir and copied into the chroot by mmdebstrap's copy-in hook: in unshare
# mode the hooks run as a subuid and cannot read the caller's 0600 files.
INPUTS="${WORK}/inputs"
umask 077
mkdir -p "${INPUTS}/ssh-host"
openssl passwd -6 -stdin <"${SECRETS_DIR}/${ADMIN_USER}-console-password" >"${INPUTS}/password.hash"
cp "${SECRETS_DIR}"/ssh-host/ssh_host_* "${INPUTS}/ssh-host/"
: >"${INPUTS}/authorized_keys"
nkeys=0
if [[ -r "${AUTHORIZED_KEYS}" ]]; then
	while IFS= read -r line; do
		[[ -z "${line//[[:space:]]/}" || "${line}" == \#* ]] && continue
		if ssh-keygen -l -f /dev/stdin <<<"${line}" >>"${WORK}/key-fingerprints.txt" 2>/dev/null; then
			echo "${line}" >>"${INPUTS}/authorized_keys"
			nkeys=$((nkeys + 1))
		else
			log "WARNING: skipping an unparsable line in ${AUTHORIZED_KEYS}"
		fi
	done <"${AUTHORIZED_KEYS}"
fi
if (( nkeys == 0 )); then
	log "WARNING: no usable public keys in ${AUTHORIZED_KEYS}: the image gets NO ssh login (console password only)"
	cat >"${STAGE}/NOTE-no-ssh-keys.txt" <<EOF
No public keys were found in ${AUTHORIZED_KEYS} at build time, so ${ADMIN_USER} has no
authorized_keys in this image. Add keys there (or set AUTHORIZED_KEYS=...) and rebuild.
EOF
fi
umask 022
log "build ${BUILD_ID}: ${SUITE}/${ARCH} from ${MIRROR}, mode ${MODE}, ${nkeys} ssh key(s), zone ${TZ_NAME}"

PKGS="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "${PACKAGES_FILE}" | grep -v '^$' | paste -sd,)"

export BUILD_ID SUITE TZ_NAME DEFAULT_HOSTNAME ADMIN_USER COMPONENTS RUNTIME_MIRROR \
	RUNTIME_SECURITY_MIRROR LOCALE_NAME BUILD_MIRROR="${MIRROR}" OVERLAY_DIR="${HERE}/overlay"

# --- 1. rootfs (rootless) ----------------------------------------------------------------------
# apt archive cache: debs are re-used between builds (sync-in) and refreshed (sync-out).
mkdir -p "${APT_CACHE}"
log "mmdebstrap (this downloads/installs ~$(wc -l <"${PACKAGES_FILE}") listed packages + deps)"
nice -n 10 ionice -c3 mmdebstrap \
	--mode="${MODE}" --variant=minbase --architectures="${ARCH}" \
	--components="${COMPONENTS}" \
	--aptopt='APT::Install-Recommends "false"' \
	--aptopt='APT::Install-Suggests "false"' \
	--include="${PKGS}" \
	--setup-hook="cp -a '${HERE}/overlay/.' \"\$1\"/" \
	--setup-hook='mkdir -p "$1"/var/cache/apt/archives' \
	--setup-hook="sync-in '${APT_CACHE}' /var/cache/apt/archives" \
	--customize-hook="sync-out /var/cache/apt/archives '${APT_CACHE}'" \
	--customize-hook="copy-in '${INPUTS}' /tmp" \
	--customize-hook="'${HERE}/hooks/customize.sh' \"\$1\"" \
	--customize-hook="copy-out /export '${STAGE}'" \
	--customize-hook="'${HERE}/hooks/tidy.sh' \"\$1\"" \
	"${SUITE}" "${WORK}/rootfs.tar" "${MIRROR}"
if [[ -d "${STAGE}/export" ]]; then
	mv "${STAGE}"/export/* "${STAGE}/"
	rmdir "${STAGE}/export"
fi
[[ -s "${STAGE}/vmlinuz" && -s "${STAGE}/initrd.img" ]] || die "kernel/initrd were not exported from the chroot"
find "${APT_CACHE}" -maxdepth 1 -name '*.deb' -mtime +21 -delete 2>/dev/null || true
rm -rf "${APT_CACHE}/partial" "${APT_CACHE}/lock" 2>/dev/null || true
log "rootfs.tar: $(du -h "${WORK}/rootfs.tar" | cut -f1)"

# --- 2. squashfs --------------------------------------------------------------------------------
log "mksquashfs (${SQUASHFS_COMP} level ${SQUASHFS_LEVEL}, block ${SQUASHFS_BLOCK})"
comp_opts=()
case "${SQUASHFS_COMP}" in
zstd) comp_opts=(-Xcompression-level "${SQUASHFS_LEVEL}") ;;
xz) comp_opts=(-Xdict-size 100%) ;;
esac
nice -n 10 ionice -c3 mksquashfs - "${STAGE}/filesystem.squashfs" -tar -noappend -no-progress \
	-comp "${SQUASHFS_COMP}" "${comp_opts[@]}" -b "${SQUASHFS_BLOCK}" \
	-processors "${SQUASHFS_PROCESSORS}" \
	<"${WORK}/rootfs.tar" >/dev/null

# --- 3. metadata, checksums -------------------------------------------------------------------------
{
	echo "build_id=${BUILD_ID}"
	echo "suite=${SUITE}"
	echo "arch=${ARCH}"
	echo "kernel=$(cat "${STAGE}/KERNEL_VERSION")"
	echo "build_mirror=${MIRROR}"
	echo "runtime_mirror=${RUNTIME_MIRROR}"
	echo "time_zone=${TZ_NAME}"
	echo "squashfs_comp=${SQUASHFS_COMP} level=${SQUASHFS_LEVEL} block=${SQUASHFS_BLOCK}"
	echo "squashfs_bytes=$(stat -c %s "${STAGE}/filesystem.squashfs")"
	echo "initrd_bytes=$(stat -c %s "${STAGE}/initrd.img")"
	echo "vmlinuz_bytes=$(stat -c %s "${STAGE}/vmlinuz")"
	echo "rootfs_tar_bytes=$(stat -c %s "${WORK}/rootfs.tar")"
	echo "packages=$(wc -l <"${STAGE}/packages.txt")"
	echo "authorized_keys=${nkeys}"
	echo "built_by=$(id -un)@$(hostname) at $(date -Is)"
} >"${STAGE}/MANIFEST"
[[ -s "${WORK}/key-fingerprints.txt" ]] && cp "${WORK}/key-fingerprints.txt" "${STAGE}/authorized-key-fingerprints.txt"
for t in ed25519 ecdsa rsa; do
	ssh-keygen -l -f "${SSH_HOST_KEY_DIR}/ssh_host_${t}_key.pub"
done >"${STAGE}/ssh-host-fingerprints.txt"
rm -f "${STAGE}/KERNEL_VERSION"
(cd "${STAGE}" && sha256sum filesystem.squashfs vmlinuz initrd.img >SHA256SUMS)
chmod 755 "${STAGE}"
chmod 644 "${STAGE}"/*

# --- 4. verify in place, then publish ---------------------------------------------------------------
verify_build "${STAGE}"
mv -T "${STAGE}" "${FINAL}"
ln -sfn "${BUILD_ID}" "${OUT_ROOT}/.current.new"
mv -T "${OUT_ROOT}/.current.new" "${OUT_ROOT}/current"
log "current -> ${BUILD_ID}"
prune_builds

log "done: ${FINAL}"
sed 's/^/  /' "${FINAL}/MANIFEST"
