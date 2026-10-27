#!/bin/bash

source "$(dirname -- "${BASH_SOURCE[0]}")/boot/lib.sh"

declare -Ag temp
cleanup_temp() {
	for key in "${!temp[@]}"; do
		echo "Clean up: ${temp[${key}]}"
		rm -rf -- "${temp[${key}]}"
	done
}
trap 'cleanup_temp' EXIT

panick() {
	local mesg str
	mesg=$1 && shift
	str=$(printf "==> ERROR: ${mesg}\n" "$@")
	echo "${str}" >&2
	exit 1
}

url2grub() {
	local url="$1"
	local url_regex='^(http|tftp)://([^/]+)(/.*)?$'
	if [[ "${url}" =~ ${url_regex} ]]; then
		local protocol="${BASH_REMATCH[1]}"
		local host="${BASH_REMATCH[2]}"
		local path="${BASH_REMATCH[3]}"
		echo "(${protocol},${host})${path}"
	fi
}

net_extract() {
	local url target workdir
	url="$1"
	target="$2"
	workdir=$(dirname "${target}")
	mkdir -p "${workdir}"

	id="net_extract_${RANDOM}"
	temp[${id}]=$(mktemp -d -p "${workdir}" .tmp.XXXXXXXX) || return 1

	curl -fsL "${url}" | bsdtar -x -f - -C "${temp[${id}]}"

	if [[ "${PIPESTATUS[0]}" == 0 && "$?" == 0 ]]; then
		chmod 755 "${temp[${id}]}"
		[[ -d "${target}" ]] && mv "${target}" "${target}.bak"
		mv "${temp[${id}]}" "${target}"
	else
		echo "Download failed"
		rm -rf "${temp[${id}]}"
		return 1
	fi
}

# Local-first downloads {{{
# Large assets are expected to be placed by the operator under ${PXE_DOWNLOADS}
# (e.g. freebsd/14.5/FreeBSD-14.5-RELEASE-amd64-disc1.iso). Scripts only fetch
# a file from the network when it is missing locally.

LAST_SHA256=""

sha256_of() {
	sha256sum -- "$1" | cut -d' ' -f1
}

# Print the hash recorded for NAME in a checksum file. Understands both
# "SHA256 (name) = hash" (FreeBSD/OpenBSD) and "hash  name" (coreutils/Debian).
# NAME is matched exactly (a leading "./" is ignored); a NAME without "/" also
# matches on the entry's basename.
sha256_lookup() {
	local sumfile="$1" name="${2#./}" line entry hash
	while IFS= read -r line || [[ -n "${line}" ]]; do
		line="${line%$'\r'}"
		if [[ "${line}" =~ ^SHA256[[:space:]]*\((.+)\)[[:space:]]*=[[:space:]]*([0-9a-fA-F]{64})$ ]]; then
			entry="${BASH_REMATCH[1]}"
			hash="${BASH_REMATCH[2]}"
		elif [[ "${line}" =~ ^([0-9a-fA-F]{64})[[:space:]]+\*?(.+)$ ]]; then
			hash="${BASH_REMATCH[1]}"
			entry="${BASH_REMATCH[2]}"
		else
			continue
		fi
		entry="${entry#./}"
		if [[ "${entry}" == "${name}" ]] \
			|| { [[ "${name}" != */* ]] && [[ "${entry##*/}" == "${name}" ]]; }; then
			echo "${hash,,}"
			return 0
		fi
	done < "${sumfile}"
	return 1
}

# verify_sha256 FILE [CHECKSUM_FILE [NAME]]
# Sets LAST_SHA256. Aborts loudly on mismatch or when CHECKSUM_FILE exists but
# has no entry for NAME (default: basename of FILE). A missing CHECKSUM_FILE only
# produces a warning.
verify_sha256() {
	local file="$1" sumfile="$2" name="${3:-$(basename -- "$1")}" expect

	[[ -s "${file}" ]] || panick "Missing or empty file: %s" "${file}"
	LAST_SHA256=$(sha256_of "${file}")

	if [[ -z "${sumfile}" || ! -f "${sumfile}" ]]; then
		echo "WARNING: no checksum file for ${file}; skipped verification (sha256=${LAST_SHA256})" >&2
		return 0
	fi

	expect=$(sha256_lookup "${sumfile}" "${name}") \
		|| panick "No SHA256 entry for '%s' in %s" "${name}" "${sumfile}"

	if [[ "${expect}" != "${LAST_SHA256}" ]]; then
		panick "SHA256 mismatch for %s\n    expected: %s\n    actual:   %s\n    checksum: %s" \
			"${file}" "${expect}" "${LAST_SHA256}" "${sumfile}"
	fi
	echo "SHA256 OK: ${file}" >&2
}

# download_local_first RELPATH [URL]
# Succeeds if ${PXE_DOWNLOADS}/RELPATH exists and is non-empty. Otherwise, when
# URL is given, fetches it there (via a .part file); returns 1 if unavailable.
download_local_first() {
	local rel="$1" url="$2" path

	[[ -n "${PXE_DOWNLOADS}" ]] || panick "\$PXE_DOWNLOADS is not set"
	path="${PXE_DOWNLOADS}/${rel}"

	if [[ -s "${path}" ]]; then
		echo "Using local file: ${path}" >&2
		return 0
	fi

	[[ -n "${url}" ]] || return 1

	echo "Local file missing, fetching ${url} -> ${path}" >&2
	mkdir -p "$(dirname -- "${path}")" || return 1
	if curl -fL --retry 3 -o "${path}.part" "${url}" && [[ -s "${path}.part" ]]; then
		mv -f "${path}.part" "${path}"
	else
		rm -f "${path}.part"
		rmdir "$(dirname -- "${path}")" 2> /dev/null
		return 1
	fi
}
# }}}

url_check() {
	local url code

	url="$1" && shift
	code=$(curl -sIL -o /dev/null -w "%{http_code}" "${url}") || return 1

	(( code < 400 )) && return 0
	for white in "$@"; do
		(( code == white )) && return 0
	done

	return 1
}

grep_web() {
	local url="$1"
	local regex="$2"
	curl -fsL "${url}" | grep -Po "${regex}" | sort -uVr
	[[ "${PIPESTATUS[0]}" == 0 ]]
}

grub_menu_sep() {
	cat <<-EOF
		menuentry '$1' {
		  true
		}
	EOF
}

grub_linux_entry() {
	local title="$1"
	local kernel="$2"
	local initrd="$3"
	local param="$4"
	cat <<-EOF
		menuentry '${title}' {
		  if [ "\${grub_platform}" = efi -a "\${grub_cpu}" = x86_64 ]; then
		    echo 'Loading kernel...'
		    linuxefi ${kernel} ${param}
		    echo 'Loading initial ramdisk...'
		    initrdefi ${initrd}
		  else
		    echo 'Loading kernel...'
		    linux ${kernel} ${param}
		    echo 'Loading initial ramdisk...'
		    initrd ${initrd}
		  fi
		}
	EOF
}

grub_option() {
	local var desc index title

	var="$1" && shift
	desc="$1" && shift

	cat <<- EOF
		if [ -z "\$${var}_INDEX" ]; then
		  set ${var}='$1'
		  set ${var}_DNAME='$2'
		  set ${var}_INDEX=0
		fi

		submenu "[option] ${desc} = \$${var}_DNAME" {
		  menuentry '${desc}:' {
		    export ${var}
		    export ${var}_DNAME
		    export ${var}_INDEX
		    configfile ${PXE_MENU_URL}
		  }
	EOF

	index=0
	while (("$#" >= 3)); do
		title="> $2"
		[[ -n "$3" ]] && title="${title}: $3"

		cat <<-EOF
			  menuentry '${title}' {
			    set ${var}='$1'
			    set ${var}_DNAME='$2'
			    set ${var}_INDEX=${index}
			    export ${var}
			    export ${var}_DNAME
			    export ${var}_INDEX
			    configfile ${PXE_MENU_URL}
			  }
		EOF

		shift 3
		index=$((index+1))
	done

	echo "}"
}

grub_mirror_selector() {
	local grub_var="$1" && shift

	declare -a buf
	for url in "$@"; do
		buf=("${buf[@]}" "${url}" "${url}" "")
	done

	grub_option "${grub_var}" "Mirror URL" "${buf[@]}"

	cat <<-EOF
		regexp \\
		--set=1:mirror_protocol \\
		--set=2:mirror_host \\
		--set=3:mirror_path \\
		'^([^:]+)://([^/]+)(/.*)\$' "\$${grub_var}"
	EOF
}

# vim: set ts=4 sw=4 sts=4 noexpandtab nosta:
