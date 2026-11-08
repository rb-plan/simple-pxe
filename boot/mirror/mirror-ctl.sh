#!/bin/bash
# Operate the intranet mirror sync: status, pause/resume, bandwidth cap, schedule.
#
#   mirror-ctl.sh status
#   mirror-ctl.sh pause                  stop running syncs and keep timers/manual runs from starting new ones
#   mirror-ctl.sh resume [--now]         allow syncs again (--now: also start the debian sync immediately)
#   mirror-ctl.sh bw KB/S|0              bandwidth cap in KiB/s, 0 = unlimited (takes effect on the next run)
#   mirror-ctl.sh schedule debian|security|diskless 'ONCALENDAR' [MAXRUNTIME]
#       e.g.  mirror-ctl.sh schedule debian '*-*-* 01:30' 4h     (runs at 01:30, killed after 4 h)
#   mirror-ctl.sh unschedule debian|security|diskless    drop the override, back to the repo default
#
# Needs sudo for everything that touches /etc or systemd.

set -euo pipefail

MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror}"
CONF="${DEBMIRROR_CONF:-/etc/debmirror-sync.conf}"
FLAG="${MIRROR_ROOT}/.paused"

unit_base() {
	case "$1" in
		debian) echo debmirror-debian ;;
		security) echo debmirror-security ;;
		diskless) echo diskless-debian-build ;;
		*) echo "unknown job '$1' (debian|security|diskless)" >&2; exit 2 ;;
	esac
}

cmd="${1:-status}"
shift || true

case "${cmd}" in
status)
	if [[ -e "${FLAG}" ]]; then echo "PAUSED since $(stat -c %y "${FLAG}")"; else echo "not paused"; fi
	echo "config ${CONF}:"; grep -E '^[A-Z_]+=' "${CONF}" 2>/dev/null | sed 's/^/  /' || echo "  (missing)"
	echo; systemctl list-timers --all --no-pager 'debmirror-*' 'diskless-*' || true
	echo; for u in debmirror-debian debmirror-security diskless-debian-build; do
		printf '%-26s %s\n' "${u}.service" "$(systemctl is-active "${u}.service" || true)"
	done
	if flock -n "${MIRROR_ROOT}/.sync.lock" true 2>/dev/null; then echo; echo "sync lock: free (no sync running)"; else echo; echo "sync lock: HELD (a sync is running)"; fi
	pgrep -af '^/usr/bin/perl .*/usr/bin/debmirror' | cut -c1-110 | sed 's/^/  /' || true
	echo; echo "tmux sessions: $(tmux ls 2>/dev/null | cut -d: -f1 | tr '\n' ' ')"
	;;
pause)
	touch "${FLAG}"
	sudo systemctl stop debmirror-debian.service debmirror-security.service 2>/dev/null
	# manual runs (tmux etc.): SIGTERM whoever holds the lock; debmirror resumes cleanly next time
	fuser -k -TERM "${MIRROR_ROOT}/.sync.lock" >/dev/null 2>&1 || true
	echo "paused: running syncs stopped, new ones exit immediately. 'mirror-ctl.sh resume' to undo."
	;;
resume)
	rm -f "${FLAG}"
	echo "resumed: timers/manual runs work again."
	if [[ "${1:-}" == "--now" ]]; then
		sudo systemctl start --no-block debmirror-debian.service
		echo "debmirror-debian.service started (follow: journalctl -fu debmirror-debian, or tail -f ${MIRROR_ROOT}/logs/debmirror-debian-latest.log)"
	fi
	;;
bw)
	n="${1:?usage: mirror-ctl.sh bw KB/S|0}"
	[[ "${n}" =~ ^[0-9]+$ ]] || { echo "not a number: ${n}" >&2; exit 2; }
	if sudo grep -q '^BWLIMIT_KBPS=' "${CONF}" 2>/dev/null; then
		sudo sed -i "s/^BWLIMIT_KBPS=.*/BWLIMIT_KBPS=${n}/" "${CONF}"
	else
		echo "BWLIMIT_KBPS=${n}" | sudo tee -a "${CONF}" >/dev/null
	fi
	echo "BWLIMIT_KBPS=${n} KB/s (0 = unlimited); applies from the next sync run. A running sync keeps its old cap: pause + resume --now to apply at once."
	;;
schedule)
	job="$(unit_base "${1:?usage: schedule JOB ONCALENDAR [MAXRUNTIME]}")"
	cal="${2:?usage: schedule JOB ONCALENDAR [MAXRUNTIME]}"
	max="${3:-}"
	systemd-analyze calendar "${cal}" >/dev/null
	sudo mkdir -p "/etc/systemd/system/${job}.timer.d"
	printf '[Timer]\nOnCalendar=\nOnCalendar=%s\nPersistent=false\n' "${cal}" | sudo tee "/etc/systemd/system/${job}.timer.d/schedule.conf" >/dev/null
	if [[ -n "${max}" ]]; then
		sudo mkdir -p "/etc/systemd/system/${job}.service.d"
		printf '[Service]\nRuntimeMaxSec=%s\n' "${max}" | sudo tee "/etc/systemd/system/${job}.service.d/schedule.conf" >/dev/null
	fi
	sudo systemctl daemon-reload
	sudo systemctl try-restart "${job}.timer"
	systemctl list-timers --all --no-pager "${job}.timer" || true
	;;
unschedule)
	job="$(unit_base "${1:?usage: unschedule JOB}")"
	sudo rm -rf "/etc/systemd/system/${job}.timer.d" "/etc/systemd/system/${job}.service.d"
	sudo systemctl daemon-reload
	sudo systemctl try-restart "${job}.timer"
	;;
*)
	sed -n '2,13p' "$0"; exit 2 ;;
esac
