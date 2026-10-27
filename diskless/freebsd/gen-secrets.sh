#!/bin/bash
# Create the secrets the diskless FreeBSD tree bakes in (idempotent: existing files are kept).
#
#   <SECRETS_DIR>/ssh-host-freebsd/ssh_host_{ed25519,ecdsa,rsa}_key[.pub]   shared host keys
#   <SECRETS_DIR>/freebsd-nick-console-password                              random password
#
# SECRETS_DIR (default /srv/pxe-images/secrets) must stay outside git and outside every web
# root. Nothing here is ever printed except the public key fingerprints.
#
#   diskless/freebsd/gen-secrets.sh            # create what is missing
#   diskless/freebsd/gen-secrets.sh --rotate   # replace everything (clients will see a host
#                                              # key change)

set -euo pipefail

: "${SECRETS_DIR:=/srv/pxe-images/secrets}"
: "${ADMIN_USER:=nick}"
KEYDIR="${SECRETS_DIR}/ssh-host-freebsd"
PWFILE="${SECRETS_DIR}/freebsd-${ADMIN_USER}-console-password"

umask 077
mkdir -p "${KEYDIR}"
chmod 700 "${SECRETS_DIR}" "${KEYDIR}"

if [[ "${1:-}" == --rotate ]]; then
	rm -f "${KEYDIR}"/ssh_host_* "${PWFILE}"
fi

gen_key() {
	local type="$1" bits="${2:-}"
	local f="${KEYDIR}/ssh_host_${type}_key"
	[[ -s "${f}" && -s "${f}.pub" ]] && return 0
	rm -f "${f}" "${f}.pub"
	ssh-keygen -q -t "${type}" ${bits:+-b "${bits}"} -N '' -C "freebsd-diskless-shared-host-key" -f "${f}"
	chmod 600 "${f}"
	chmod 644 "${f}.pub"
	echo "created ${f}"
}
gen_key ed25519
gen_key ecdsa 256
gen_key rsa 3072

if [[ ! -s "${PWFILE}" ]]; then
	secret="$(openssl rand -base64 64 | LC_ALL=C tr -dc 'A-Za-z0-9')"
	echo "${secret:0:24}" >"${PWFILE}.tmp"
	unset secret
	chmod 600 "${PWFILE}.tmp"
	mv "${PWFILE}.tmp" "${PWFILE}"
	echo "created ${PWFILE}"
fi

for f in "${KEYDIR}"/ssh_host_*_key; do
	ssh-keygen -l -f "${f}.pub"
done
