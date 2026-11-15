#!/usr/bin/env bash
#
# restore-mysql.sh - Restore a backup made by backup-mysql.sh into a container.
#
# Usage:
#   restore-mysql.sh CONTAINER            restore the latest backup
#   restore-mysql.sh CONTAINER FILE       restore a specific .sql.gz file
#   restore-mysql.sh --list CONTAINER     list available backups
#
# The dump contains every database (including the mysql system schema), so a
# restore replaces all of them. You are asked to type the container name to
# confirm.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="/opt/backupsql/sqlbackup"

for candidate in "${BACKUP_CONFIG:-}" "$SCRIPT_DIR/backup.conf" "/etc/mysql-backup/backup.conf"; do
	if [ -n "$candidate" ] && [ -f "$candidate" ]; then
		# shellcheck source=backup.conf.example
		. "$candidate"
		break
	fi
done

usage() {
	sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
	echo "Error: $*" >&2
	exit 1
}

if [ "${1:-}" = "--list" ]; then
	[ -n "${2:-}" ] || { usage >&2; exit 2; }
	dir="$BACKUP_ROOT/$2"
	[ -d "$dir" ] || die "no backups directory at $dir"
	ls -lht "$dir"/db_backup_*.sql.gz 2>/dev/null || echo "No backups in $dir"
	exit 0
fi

case "${1:-}" in
	"" | -h | --help)
		usage
		exit 0
		;;
esac

container="$1"
dir="$BACKUP_ROOT/$container"
file="${2:-$dir/latest_db_backup.sql.gz}"

[ -f "$file" ] || die "backup file not found: $file"
docker ps --format '{{.Names}}' | grep -qx -- "$container" || die "container '$container' is not running"

echo "Checking $file ..."
gzip -t "$file" || die "$file is not a valid gzip file"

echo
echo "This will REPLACE ALL DATABASES in '$container' with:"
echo "  $(readlink -f "$file") ($(du -h "$file" | cut -f1))"
echo
read -r -p "Type the container name to continue: " answer
[ "$answer" = "$container" ] || die "confirmation did not match; nothing was changed"

echo "Restoring..."
gunzip -c "$file" | docker exec -i "$container" sh -c '
	MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u root
'
status=("${PIPESTATUS[@]}")

if [ "${status[0]}" -ne 0 ] || [ "${status[1]}" -ne 0 ]; then
	die "restore failed (gunzip=${status[0]}, mysql=${status[1]})"
fi

echo "Restore complete. Restart the app containers if they cache connections."
