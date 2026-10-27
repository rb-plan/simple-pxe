# Hub-local Debian mirror

Partial mirror of USTC for the intranet: amd64 (+all), suites bookworm and trixie with
`-updates`, plus `debian-security`; components `main contrib non-free-firmware` (no
`non-free`), udebs and d-i installer images included, no sources, no Contents, no pdiff.

| What | Where |
|---|---|
| Data | ZFS dataset `vms/mirror` (quota 400G) mounted on `/srv/mirror` (`debian/`, `debian-security/`, `logs/`) |
| Sync script | `boot/mirror/debmirror-sync.sh main\|security\|all` (as user nick, nice + ionice idle, flock) |
| Units | `boot/mirror/systemd/` installed in `/etc/systemd/system/`: `debmirror-debian.timer` (daily 03:30 +-30 min), `debmirror-security.timer` (every 6 h at :15) |
| nginx | `boot/mirror/nginx-mirror-location.conf` = `/opt/bsdfile/nginx/hub/mirror-location.inc` (http `/debian/`, `/debian-security/`, private networks only, autoindex on) |
| Switch simple-pxe | `boot/mirror/use-local-mirror.sh check\|on\|off` |

Notes

* USTC's rsync service answers `@ERROR: Access denied` to this host after debmirror's many
  short connections, and its HTTP server answers 403 to the default `libwww-perl` User-Agent.
  The script therefore uses HTTP and loads `perl/DebmirrorUA.pm` (User-Agent `debmirror/...`).
  `DEBMIRROR_METHOD=rsync` switches back.
* debmirror writes `dists/*/Release` only at the very end of a run (pool first), so a mirror
  that is still on its first sync has no `Release` files and `apt` cannot use it yet.
* Progress: `tail -f /srv/mirror/logs/debmirror-debian-*.log`, `du -sh /srv/mirror/debian`,
  `systemctl list-timers 'debmirror*'`, `journalctl -u debmirror-debian`.
