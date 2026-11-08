#!/usr/bin/env python3
"""Run one command as root on the guest: ssh as the admin user (key), then `su root -c`
with the root password read from the secrets file (never printed).

    as-root.py <ip> '<command>'
"""
import os, pty, select, sys, time

ip, cmd = sys.argv[1], sys.argv[2]
secrets = os.environ.get("SECRETS_DIR", "/srv/pxe-images/secrets")
user = os.environ.get("ADMIN_USER", "nick")
pw = open(f"{secrets}/freebsd-root-console-password").read().strip()
quoted = cmd.replace("'", "'\"'\"'")
argv = ["ssh", "-tt", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10", f"{user}@{ip}",
        f"su root -c '{quoted}'; echo __rc=$?"]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
buf, sent, end = b"", False, time.time() + 60
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 1)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if not sent and b"assword:" in buf:
            os.write(fd, (pw + "\n").encode())
            sent = True
os.waitpid(pid, 0)
text = buf.decode(errors="replace").replace("\r", "")
text = text.split("assword:", 1)[-1].lstrip("\n")
print(text.rstrip())
sys.exit(0 if "__rc=0" in text else 1)
