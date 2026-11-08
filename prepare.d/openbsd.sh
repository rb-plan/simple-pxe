#!/bin/bash
#root: openbsd

# OpenBSD network install, local-first: everything comes from ${PXE_DOWNLOADS}/openbsd/<ver>/amd64
# (the operator downloads it there, see boot/openbsd/README.md), is checked with signify against
# SHA256.sig, and is then hard-linked into ${PXE_LOCAL_ROOT}/openbsd/<ver>/amd64, a directory
# that looks like an OpenBSD mirror so the installer can use it as HTTP source
# (server = the hub, directory = <PXE_HTTP_ROOT path>/openbsd/<ver>/amd64).
# The small boot files (pxeboot, BOOTX64.EFI, bsd.rd, BUILDINFO, SHA256, SHA256.sig, ~5 MB) are fetched
# from ${OPENBSD_MIRROR} when missing; the install sets (~800 MB) only with OPENBSD_FETCH_SETS=1.

source functions.sh
repo="${PWD}"
cd "${LOCAL_PATH}" || exit 1
openbsd_defaults

ver="${OPENBSD_VERSION}"
nodot="${OPENBSD_NODOT}"
arch=amd64
rel="openbsd/${ver}/${arch}"
src="${PXE_DOWNLOADS}/${rel}"
dst="${LOCAL_PATH}/${ver}/${arch}"
url="${OPENBSD_MIRROR}/${ver}/${arch}"
sets_all=(base man comp game xbase xfont xserv xshare)
kernels=(bsd bsd.mp)   # the installer lists and fetches these as well; a set install fails without "bsd"

signify="$(command -v signify-openbsd || command -v signify)" \
	|| panick "signify not found (apt install signify-openbsd)"

# 1. small boot files, local first
for f in SHA256 SHA256.sig pxeboot BOOTX64.EFI bsd.rd BUILDINFO; do
	download_local_first "${rel}/${f}" "${url}/${f}" \
		|| panick "OpenBSD %s: %s missing locally and not downloadable from %s" "${ver}" "${f}" "${url}"
done

# 2. signify key: next to the files, else the system one (OpenBSD box: /etc/signify)
key=""
for k in "${PXE_DOWNLOADS}/openbsd/${ver}/openbsd-${nodot}-base.pub" "/etc/signify/openbsd-${nodot}-base.pub"; do
	[[ -s "${k}" ]] && { key="${k}"; break; }
done
[[ -n "${key}" ]] || panick "No signify key openbsd-%s-base.pub: copy it from an OpenBSD box (/etc/signify/) to %s/openbsd/%s/" \
	"${nodot}" "${PXE_DOWNLOADS}" "${ver}"
echo "signify key: ${key}"

# 3. verify every present file that SHA256.sig lists (the signed message is the file list)
cd "${src}" || exit 1
listed="$("${signify}" -V -e -p "${key}" -x SHA256.sig -m - 2> /dev/null | sed -nE 's/^SHA256 \((.+)\) = .*/\1/p')" \
	|| panick "SHA256.sig does not verify with %s" "${key}"
[[ -n "${listed}" ]] || panick "SHA256.sig does not verify with %s" "${key}"
present=()
missing_sets=()
while read -r name; do
	if [[ -s "${name}" ]]; then
		present+=("${name}")
	fi
done <<< "${listed}"
for s in "${sets_all[@]}"; do
	[[ -s "${s}${nodot}.tgz" ]] || missing_sets+=("${s}${nodot}.tgz")
done
for k in "${kernels[@]}"; do
	[[ -s "${k}" ]] || missing_sets+=("${k}")
done
if [[ "${OPENBSD_FETCH_SETS:-0}" == 1 && ${#missing_sets[@]} -gt 0 ]]; then
	for f in "${missing_sets[@]}"; do
		download_local_first "${rel}/${f}" "${url}/${f}" || echo "WARNING: could not fetch ${url}/${f}" >&2
	done
	missing_sets=()
	present=()
	while read -r name; do [[ -s "${name}" ]] && present+=("${name}"); done <<< "${listed}"
	for s in "${sets_all[@]}"; do [[ -s "${s}${nodot}.tgz" ]] || missing_sets+=("${s}${nodot}.tgz"); done
	for k in "${kernels[@]}"; do [[ -s "${k}" ]] || missing_sets+=("${k}"); done
fi
"${signify}" -C -p "${key}" -x SHA256.sig -- "${present[@]}" \
	|| panick "signify check failed for files in %s (re-download the failing files)" "${src}"

# 4. publish: hard links (same filesystem) or copies; installer-mirror layout
mkdir -p "${dst}"
for f in "${present[@]}" SHA256 SHA256.sig; do
	ln -f "${src}/${f}" "${dst}/${f}" 2> /dev/null || cp -f "${src}/${f}" "${dst}/${f}"
done
# index.txt (ls -l format like the real mirrors): the installer lists the sets from it when
# the HTTP server has no directory listing (nginx autoindex off -> 403).
(cd "${dst}" && rm -f index.txt && LC_ALL=C ls -l "${present[@]}" SHA256 SHA256.sig \
	| sed -E 's/^(.{10}) +[0-9]+ +[^ ]+ +[^ ]+ +/\1  1 root  wheel  /' > index.txt.new && mv -f index.txt.new index.txt)
chmod 755 "${LOCAL_PATH}" "${LOCAL_PATH}/${ver}" "${dst}"
chmod 644 "${dst}"/*
echo "Published ${#present[@]} verified files to ${dst}"

# 5. install.conf for autoinstall: the operator's own ${PXE_DOWNLOADS}/openbsd/install.conf,
#    else the template with the hub/path of PXE_HTTP_ROOT filled in
http_host="$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<< "${PXE_HTTP_ROOT}")"
http_path="$(sed -E 's#^[a-z]+://[^/]+/?##; s#/$##' <<< "${PXE_HTTP_ROOT}")"
if [[ -s "${PXE_DOWNLOADS}/openbsd/install.conf" ]]; then
	install -m644 "${PXE_DOWNLOADS}/openbsd/install.conf" "${LOCAL_PATH}/install.conf"
else
	sed -e "s#@HTTP_HOST@#${http_host}#g" \
		-e "s#@HTTP_DIR@#${http_path:+${http_path}/}openbsd/${ver}/${arch}#g" \
		-e "s#@COM0_SPEED@#${OPENBSD_COM0_SPEED}#g" \
		-e "s#@ROOT_PW@#${OPENBSD_ROOT_PASSWORD_HASH:-*************}#g" \
		-e "s#@COM0@#$([[ "${OPENBSD_CONSOLE}" == com0 ]] && echo yes || echo no)#g" \
		"${repo}/boot/openbsd/install.conf.in" > "${LOCAL_PATH}/install.conf"
	chmod 644 "${LOCAL_PATH}/install.conf"
fi

# 6. report what the operator still has to download
if (( ${#missing_sets[@]} > 0 )); then
	echo
	echo "WARNING: OpenBSD ${ver} install sets missing in ${src} (the installer boots, but an HTTP install needs them):" >&2
	for f in "${missing_sets[@]}"; do echo "    ${url}/${f}" >&2; done
	echo "  (at least bsd and base${nodot}.tgz; or: OPENBSD_FETCH_SETS=1 ./simple-pxe prepare)" >&2
fi
exit 0
