#!/bin/bash
# Verify a booted diskless guest over SSH as nick (key auth) from this host.
#   diskless/debian/verify-guest.sh <guest-ip> [expected-hostname]
# Prints results only; never reads or prints the console password.
set -uo pipefail

IP="${1:?guest ip}"
WANT_HOST="${2:-}"
SECRETS_DIR="${SECRETS_DIR:-/srv/pxe-images/secrets}"
HERE="$(cd "$(dirname -- "$0")" && pwd)"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR -o ConnectTimeout=8 "nick@${IP}")

ok() { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; rc=1; }
rc=0

for _ in $(seq 1 30); do "${SSH[@]}" true 2>/dev/null && break; sleep 3; done
"${SSH[@]}" true 2>/dev/null || { bad "ssh as nick with key"; exit 1; }
ok "ssh as nick with key"

# host keys: fingerprint of the key offered by the guest vs stored pub keys
for t in ed25519 ecdsa rsa; do
	want="$(ssh-keygen -lf "${SECRETS_DIR}/ssh-host/ssh_host_${t}_key.pub" | awk '{print $2}')"
	got="$(ssh-keyscan -t "${t}" "${IP}" 2>/dev/null | ssh-keygen -lf - | awk '{print $2}')"
	[[ -n "${got}" && "${got}" == "${want}" ]] && ok "host key ${t} matches stored (${want})" || bad "host key ${t}: got '${got}' want '${want}'"
done

# negative auth tests
if ssh -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 "nick@${IP}" true 2>/dev/null; then
	bad "password login must be refused"
else ok "password login refused"; fi
if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
	-o ConnectTimeout=8 "root@${IP}" true 2>/dev/null; then
	bad "root login must be refused"
else ok "root login refused"; fi

# the checks inside the guest
"${SSH[@]}" 'bash -s' <<'EOS'
echo "--- hostname: $(hostname)   machine-id: $(cat /etc/machine-id)"
echo "--- kernel: $(uname -r)   cmdline: $(sed -E 's/(password|pass)=[^ ]*/\1=***/g' /proc/cmdline)"
echo "--- date: $(date)"
echo "--- timezone: $(timedatectl show -p Timezone --value 2>/dev/null)"
echo "--- id: $(id)"
echo "--- sshd: $(systemctl is-active ssh)"
echo "--- dpkg packages installed: $(dpkg -l | grep -c ^ii)"
echo "--- sudo -n true: $(sudo -n true 2>&1 && echo ok || echo 'needs password (expected if no NOPASSWD)')"
echo "--- free -m"; free -m
echo "--- df (live overlay)"; df -h / /run 2>/dev/null
echo "--- ip"; ip -br addr; ip route
echo "--- nic drivers"; for n in /sys/class/net/*; do [ "$(basename "$n")" = lo ] || echo "$(basename "$n"): $(basename "$(readlink "$n/device/driver" 2>/dev/null)")"; done
echo "--- tools"
dig -v 2>&1 | head -1
cowsay -f default "diskless ok" | head -3
/usr/games/fortune -s | head -2
echo "https://example.org" | qrencode -t ANSIUTF8 | head -3
nmap --version | head -1
EOS
echo "--- package check"
"${SSH[@]}" "dpkg -l | awk '\$1==\"ii\"{sub(/:.*/,\"\",\$2); print \$2\" ii\"}'" >/tmp/verify-guest.dpkg.$$ 2>/dev/null
for p in vim sudo openssh-server wget curl net-tools nfs-common openssl git htop bind9-dnsutils nmap qrencode cowsay fortunes fortune-mod unzip \
	linux-image-amd64 live-boot initramfs-tools systemd-sysv ca-certificates iproute2 firmware-realtek firmware-misc-nonfree locales; do
	grep -q "^${p} ii" /tmp/verify-guest.dpkg.$$ && ok "package ${p}" || bad "package ${p}"
done
rm -f /tmp/verify-guest.dpkg.$$
if [[ -n "${WANT_HOST}" ]]; then
	got="$("${SSH[@]}" hostname 2>/dev/null)"
	[[ "${got}" == "${WANT_HOST}" ]] && ok "hostname from DHCP (${got})" || bad "hostname '${got}' != '${WANT_HOST}'"
fi
exit "${rc}"
