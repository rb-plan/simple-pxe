#!/bin/bash
# Create the secrets the diskless image bakes in (idempotent: existing files are kept).
#
#   <SECRETS_DIR>/ssh-host/ssh_host_{ed25519,ecdsa,rsa}_key[.pub]   one shared host key set
#   <SECRETS_DIR>/nick-console-password                             random console password
#
# SECRETS_DIR (default /srv/pxe-images/secrets) must stay outside git and outside every
# web root. Nothing here is ever printed.
#
#   diskless/debian/gen-secrets.sh            # create what is missing
#   diskless/debian/gen-secrets.sh --rotate   # replace everything (new host keys: clients
#                                             # will see a host key change!)

set -euo pipefail

HERE="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "${HERE}/build.conf" ]] && source "${HERE}/build.conf"
: "${SECRETS_DIR:=/srv/pxe-images/secrets}"
: "${ADMIN_USER:=nick}"

umask 077
mkdir -p "${SECRETS_DIR}/ssh-host"
chmod 700 "${SECRETS_DIR}" "${SECRETS_DIR}/ssh-host"

if [[ "${1:-}" == --rotate ]]; then
	rm -f "${SECRETS_DIR}"/ssh-host/ssh_host_* "${SECRETS_DIR}/${ADMIN_USER}-console-password"
fi

gen_key() {
	local type="$1" bits="${2:-}"
	local f="${SECRETS_DIR}/ssh-host/ssh_host_${type}_key"
	[[ -s "${f}" && -s "${f}.pub" ]] && return 0
	rm -f "${f}" "${f}.pub"
	ssh-keygen -q -t "${type}" ${bits:+-b "${bits}"} -N '' -C "diskless-shared-host-key" -f "${f}"
	chmod 600 "${f}"
	chmod 644 "${f}.pub"
	echo "created ${f}"
}
gen_key ed25519
gen_key ecdsa 256
gen_key rsa 3072

pw="${SECRETS_DIR}/${ADMIN_USER}-console-password"
if [[ ! -s "${pw}" ]]; then
	# 24 characters of [A-Za-z0-9], no shell-hostile characters
	secret="$(openssl rand -base64 64 | LC_ALL=C tr -dc 'A-Za-z0-9')"
	echo "${secret:0:24}" >"${pw}.tmp"
	unset secret
	chmod 600 "${pw}.tmp"
	mv "${pw}.tmp" "${pw}"
	echo "created ${pw}"
fi

for f in "${SECRETS_DIR}"/ssh-host/ssh_host_*_key; do
	ssh-keygen -l -f "${f}.pub"
done
