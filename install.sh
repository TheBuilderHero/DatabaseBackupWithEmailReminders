#!/usr/bin/env bash
#
# install.sh - Set up backup-mysql.sh on the server. Run as root from the
# cloned repository. Safe to re-run: it never overwrites an existing config.
#
# Usage:
#   sudo ./install.sh                       daily at 02:00
#   sudo ./install.sh --schedule "0 3 * * *"
#   sudo ./install.sh --uninstall           remove cron + logrotate entries

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/mysql-backup"
CONFIG_FILE="$CONFIG_DIR/backup.conf"
CRON_FILE="/etc/cron.d/mysql-backup"
LOGROTATE_FILE="/etc/logrotate.d/mysql-backup"
LOG_FILE="/var/log/mysql-backup.log"
SCHEDULE="0 2 * * *"

while [ $# -gt 0 ]; do
	case "$1" in
		--schedule)
			SCHEDULE="${2:?--schedule needs a cron expression}"
			shift 2
			;;
		--uninstall)
			rm -f "$CRON_FILE" "$LOGROTATE_FILE"
			echo "Removed $CRON_FILE and $LOGROTATE_FILE."
			echo "Left $CONFIG_FILE, $LOG_FILE and all backups in place."
			exit 0
			;;
		-h | --help)
			sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 2
			;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo ./install.sh)." >&2; exit 1; }

echo "Checking dependencies..."
missing=0
for cmd in docker gzip zcat flock find; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "  missing: $cmd"
		missing=1
	fi
done
if [ ! -x /usr/sbin/sendmail ]; then
	echo "  missing: /usr/sbin/sendmail (install ssmtp, or msmtp + msmtp-mta)"
	echo "           backups still run without it, but no emails are sent"
fi
[ "$missing" -eq 0 ] || { echo "Install the missing commands and re-run." >&2; exit 1; }

chmod 755 "$REPO_DIR/backup-mysql.sh" "$REPO_DIR/restore-mysql.sh"

mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_FILE" ]; then
	echo "Keeping existing $CONFIG_FILE"
else
	install -m 600 "$REPO_DIR/backup.conf.example" "$CONFIG_FILE"
	echo "Created $CONFIG_FILE - edit it to set EMAIL_TO before the first run."
fi

cat >"$CRON_FILE" <<EOF
# Installed by $REPO_DIR/install.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$SCHEDULE root $REPO_DIR/backup-mysql.sh >> $LOG_FILE 2>&1
EOF
chmod 644 "$CRON_FILE"
echo "Installed $CRON_FILE ($SCHEDULE)"

cat >"$LOGROTATE_FILE" <<EOF
$LOG_FILE {
	monthly
	rotate 12
	compress
	missingok
	notifempty
}
EOF
chmod 644 "$LOGROTATE_FILE"
echo "Installed $LOGROTATE_FILE"

echo
echo "Next steps:"
echo "  1. Edit $CONFIG_FILE"
echo "  2. $REPO_DIR/backup-mysql.sh --test-email"
echo "  3. $REPO_DIR/backup-mysql.sh            (one manual run)"
echo "  4. Remove any old crontab entry for the previous backup script (crontab -e)"
