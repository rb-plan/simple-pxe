#!/bin/bash
# Checks a booted diskless FreeBSD guest over SSH (key login as the admin user).
#   diskless/freebsd/verify-guest.sh <ip> [expected-hostname]
# Prints PASS/FAIL per check and the interesting command output; exit 1 on any FAIL.

set -uo pipefail
HERE="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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

out="$(g 'uname -srm; id; hostname; date +%z; date; mount; ifconfig -a; cat /var/db/zoneinfo; sysctl -n kern.console; ps ax -o command | grep -E "getty|sshd" | grep -v grep; kenv console 2>&1; kenv boot_multicons 2>&1; cat /etc/resolv.conf 2>&1' 2>&1)" \
	&& ok "ssh ${ADMIN_USER}@${IP} with key" || { bad "ssh key login: ${out}"; exit 1; }
echo "${out}" | sed 's/^/      /'

grep -q "^FreeBSD 15.1-RELEASE" <<<"${out}" && ok "FreeBSD 15.1-RELEASE amd64" || bad "uname"
grep -q "^uid=1001(${ADMIN_USER}).*wheel" <<<"${out}" && ok "${ADMIN_USER} in wheel" || bad "wheel membership"
grep -qE '^\+0800$' <<<"${out}" && ok "date offset +0800" || bad "timezone"
grep -qE ' on / \(nfs' <<<"${out}" && ok "root is NFS" || bad "root fs is not NFS"
grep -qE '^(tmpfs|/dev/md[0-9]+) on /etc ' <<<"${out}" && ok "/etc is a memory fs" || bad "/etc not memory"
grep -qE '^(tmpfs|/dev/md[0-9]+) on /var ' <<<"${out}" && ok "/var is a memory fs" || bad "/var not memory"
grep -qE '^inet [0-9.]+ ' <<<"$(grep -E '^\s+inet ' <<<"${out}" | sed 's/^\s*//' | grep -v '127.0.0.1')" && ok "interface has an IPv4 address" || bad "no IPv4 address"
[[ -z "${WANT_HOST}" ]] || { [[ "$(g hostname)" == "${WANT_HOST}" ]] && ok "hostname ${WANT_HOST} (from DHCP)" || bad "hostname"; }
grep -q 'getty.*ttyu0' <<<"${out}" && ok "getty on ttyu0 (serial console)" || bad "no getty on ttyu0"

rootout="$("${HERE}/as-root.py" "${IP}" 'id -un; touch /etc/.t && rm /etc/.t && echo etc-rw; touch /var/.t && rm /var/.t && echo var-rw; touch /tmp/.t && rm /tmp/.t && echo tmp-rw; touch /home/.t && rm /home/.t && echo home-rw; touch /usr/.t 2>&1; touch /boot/.t 2>&1; ls -l /etc/resolv.conf; test -s /etc/pwd.db && echo pwdb-ok; mount -t nfs' 2>&1)" || bad "su root (console password) failed"
echo "${rootout}" | sed 's/^/      /'
grep -q '^root$' <<<"${rootout}" && ok "su root with the console password works" || bad "su root"
for d in etc var tmp home; do grep -q "^${d}-rw$" <<<"${rootout}" && ok "/${d} writable (memory)" || bad "/${d} not writable"; done
grep -q 'usr/.t: Read-only file system' <<<"${rootout}" && ok "write to /usr refused: Read-only file system" || bad "/usr is writable"
grep -q 'boot/.t: Read-only file system' <<<"${rootout}" && ok "write to /boot refused: Read-only file system" || bad "/boot is writable"
grep -q '^pwdb-ok$' <<<"${rootout}" && ok "pwd.db rebuilt at boot" || bad "pwd.db missing"
grep -E ' on / \(nfs.*read-only' <<<"${rootout}" >/dev/null && ok "root NFS mounted read-only" || bad "root NFS mount not flagged read-only"
denied() { # ssh options...: retry while the guest is still busy (banner timeouts)
	local o i
	for i in 1 2 3 4; do
		o="$("${SSH[@]}" "$@" true 2>&1 || true)"
		grep -qi 'permission denied' <<<"${o}" && return 0
		sleep 3
	done
	echo "${o}" >&2; return 1
}
pwo="$(denied -o PreferredAuthentications=password -o PubkeyAuthentication=no "${ADMIN_USER}@${IP}" 2>&1 && echo "Permission denied")"
grep -qi 'permission denied' <<<"${pwo}" && ok "password SSH login refused" || bad "password login not refused: ${pwo}"
rto="$(denied "root@${IP}" 2>&1 && echo "Permission denied")"
grep -qi 'permission denied' <<<"${rto}" && ok "root SSH login refused" || bad "root login not refused: ${rto}"
exit "${fail}"
