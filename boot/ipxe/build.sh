#!/bin/bash
# Build the first-stage iPXE binaries (BIOS undionly.kpxe + ipxe.pxe, UEFI snponly.efi) from upstream
# source with an embedded script (embed.ipxe.in): DHCP, then chain ipxe/boot.ipxe over TFTP.
#
#   boot/ipxe/build.sh [out-dir]          default out-dir: ${PXE_DOWNLOADS}/ipxe
#
# Environment:
#   IPXE_REF        upstream tag/branch/commit (default v2.0.0, released 2026-03-06)
#   IPXE_SRC        checkout location (default ${PXE_DOWNLOADS}/ipxe/src)
#   IPXE_TFTP_HOST  fallback TFTP host baked into the embedded script, used only when DHCP
#                   gives no next-server (default: host of PXE_HTTP_ROOT)
#   IPXE_EXTRA      extra make targets, e.g. "bin-x86_64-efi/ipxe.efi" (copied to out-dir too)
#   IPXE_JOBS       make -j (default 4)
#
# Build deps (Debian): git make gcc binutils perl liblzma-dev (mtools only for .usb/.iso targets).
# ipxe.pxe is the BIOS build with its own NIC drivers (no UNDI): an alternative first stage, needed
# where OpenBSD pxeboot must run from the iPXE menu on top of a buggy/nested UNDI (see boot/README.md).
# Output: undionly.kpxe snponly.efi ipxe.pxe SHA256 SOURCE.txt (previous files are kept as *.bak-<date>).
# The result is unsigned: UEFI Secure Boot must stay off.

set -euo pipefail

cd "$(dirname -- "$0")/../.."
here=boot/ipxe
source config.local

DOWNLOADS="${PXE_DOWNLOADS:-$(dirname -- "${PXE_LOCAL_ROOT}")/downloads}"
OUT="${1:-${DOWNLOADS}/ipxe}"
REF="${IPXE_REF:-v2.0.0}"
SRC="${IPXE_SRC:-${DOWNLOADS}/ipxe/src}"
TFTP_HOST="${IPXE_TFTP_HOST:-$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"${PXE_HTTP_ROOT}")}"
JOBS="${IPXE_JOBS:-4}"
TARGETS=(bin/undionly.kpxe bin-x86_64-efi/snponly.efi bin/ipxe.pxe ${IPXE_EXTRA:-})

for tool in git make gcc ld perl; do
	command -v "${tool}" >/dev/null || { echo "missing build tool: ${tool}" >&2; exit 1; }
done
[[ -e /usr/include/lzma.h ]] || { echo "missing liblzma-dev (apt install liblzma-dev)" >&2; exit 1; }

if [[ ! -d "${SRC}/.git" ]]; then
	mkdir -p "$(dirname -- "${SRC}")"
	git clone https://github.com/ipxe/ipxe "${SRC}"
fi
git -C "${SRC}" fetch --quiet --tags origin 2>/dev/null || echo "WARNING: cannot fetch upstream, using the local checkout" >&2
git -C "${SRC}" checkout --quiet --force "${REF}"
COMMIT="$(git -C "${SRC}" rev-parse HEAD)"

mkdir -p "${SRC}/src/config/local"
cp "${here}/config/"*.h "${SRC}/src/config/local/"
EMBED="${SRC}/src/embed.ipxe"
sed "s#@TFTP_HOST@#${TFTP_HOST}#g" "${here}/embed.ipxe.in" >"${EMBED}"

(
	cd "${SRC}/src"
	rm -rf bin bin-x86_64-efi
	# Fixed timestamp keeps rebuilds of the same commit byte-identical where possible.
	export SOURCE_DATE_EPOCH="$(git -C .. log -1 --format=%ct)"
	make -j"${JOBS}" EMBED=embed.ipxe NO_WERROR=1 "${TARGETS[@]}"
)

mkdir -p "${OUT}"
stamp="$(date +%Y%m%d)"
for t in "${TARGETS[@]}"; do
	f="$(basename -- "${t}")"
	[[ -s "${OUT}/${f}" ]] && ! cmp -s "${OUT}/${f}" "${SRC}/src/${t}" && { [[ -e "${OUT}/${f}.bak-${stamp}" ]] || cp -p "${OUT}/${f}" "${OUT}/${f}.bak-${stamp}"; }
	cp "${SRC}/src/${t}" "${OUT}/${f}"
done
(cd "${OUT}" && sha256sum undionly.kpxe snponly.efi ipxe.pxe $(for t in ${IPXE_EXTRA:-}; do basename -- "${t}"; done) >SHA256)
cat >"${OUT}/SOURCE.txt" <<EOT
iPXE ${REF} (${COMMIT}) built by boot/ipxe/build.sh on $(date -u +%FT%TZ)
embedded script: boot/ipxe/embed.ipxe.in (fallback TFTP host ${TFTP_HOST})
config: boot/ipxe/config/{general,console}.h
unsigned; UEFI Secure Boot must be off
EOT
echo "iPXE ${REF} built into ${OUT}:"
ls -l "${OUT}" | grep -v -E 'src$|bak-'
