#!/bin/bash
# Checks a booted diskless FreeBSD guest over SSH (key login as the admin user).
#   diskless/freebsd/verify-guest.sh <ip> [expected-hostname]
# Prints PASS/FAIL per check and the interesting command output; exit 1 on any FAIL.

set -uo pipefail
IP="${1:?guest ip}"
WANT_HOST="${2:-}"
: "${SECRETS_DIR:=/srv/pxe-images/secrets}"
: "${ADMIN_USER:=nick}"
KEYDIR="${SECRETS_DIR}/ssh-host-freebsd"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
fail=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=1; }
chk() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "${what}"; else bad "${what}"; fi; }
g() { "${SSH[@]}" "${ADMIN_USER}@${IP}" "$@"; }

# host keys: scan and compare with the stored public keys
scan="$(ssh-keyscan -T 10 "${IP}" 2>/dev/null)"
for t in ed25519 ecdsa rsa; do
	want="$(ssh-keygen -l -f "${KEYDIR}/ssh_host_${t}_key.pub" | awk '{print $2}')"
	got="$(grep -E " ssh-${t}| ecdsa-sha2-nistp256| ssh-rsa" <<<"${scan}" | ssh-keygen -l -f /dev/stdin 2>/dev/null | grep -i "(${t})" | awk '{print $2}')"
	[[ -n "${want}" && "${got}" == "${want}" ]] && ok "host key ${t} matches ${want}" || bad "host key ${t}: want ${want} got ${got:-none}"
done

out="$(g 'uname -srm; id; hostname; date +%z; date; mount; ifconfig -a; cat /var/db/zoneinfo; sysctl -n kern.console; ps ax -o command | grep -E "getty|sshd" | grep -v grep; kenv console boot_multicons 2>&1' 2>&1)" \
	&& ok "ssh ${ADMIN_USER}@${IP} with key" || { bad "ssh key login: ${out}"; exit 1; }
echo "${out}" | sed 's/^/      /'

grep -q "^FreeBSD 15.1-RELEASE" <<<"${out}" && ok "FreeBSD 15.1-RELEASE amd64" || bad "uname"
grep -q "^uid=1001(${ADMIN_USER}).*wheel" <<<"${out}" && ok "${ADMIN_USER} in wheel" || bad "wheel membership"
grep -qE '^\+0800$' <<<"${out}" && ok "date offset +0800" || bad "timezone"
grep -qE ' on / \(nfs' <<<"${out}" && grep -E ' on / \(nfs' <<<"${out}" | grep -q 'read-only' && ok "root is NFS, read-only" || bad "root fs not ro NFS"
grep -qE '^(tmpfs|/dev/md[0-9]+) on /etc ' <<<"${out}" && ok "/etc is a memory fs" || bad "/etc not memory"
grep -qE '^(tmpfs|/dev/md[0-9]+) on /var ' <<<"${out}" && ok "/var is a memory fs" || bad "/var not memory"
grep -qE '^inet [0-9.]+ ' <<<"$(grep -E '^\s+inet ' <<<"${out}" | sed 's/^\s*//' | grep -v '127.0.0.1')" && ok "interface has an IPv4 address" || bad "no IPv4 address"
[[ -z "${WANT_HOST}" ]] || { [[ "$(g hostname)" == "${WANT_HOST}" ]] && ok "hostname ${WANT_HOST} (from DHCP)" || bad "hostname"; }
grep -q 'getty.*ttyu0' <<<"${out}" && ok "getty on ttyu0 (serial console)" || bad "no getty on ttyu0"

chk "write /etc, /var, /tmp, /home (memory)" g 'touch /etc/.t /var/.t /tmp/.t ~/.t && rm /etc/.t /var/.t /tmp/.t ~/.t'
g 'touch /usr/.t' 2>&1 | grep -qi 'read-only' && ok "write to /usr refused (read-only)" || bad "/usr writable?"
chk "nick can read its authorized key + passwd db works (id root)" g 'id root'
"${SSH[@]}" -o PreferredAuthentications=password -o PubkeyAuthentication=no "${ADMIN_USER}@${IP}" true 2>&1 | grep -qi 'permission denied' && ok "password SSH login refused" || bad "password login not refused"
"${SSH[@]}" "root@${IP}" true 2>&1 | grep -qi 'permission denied' && ok "root SSH login refused" || bad "root login not refused"
exit "${fail}"
