#!/usr/bin/env bash
#
# backup-mysql.sh - Dump every running MySQL container, verify the dump,
# prune old copies safely, and send an email/SMS notification.
#
# Usage:
#   backup-mysql.sh                run the backups
#   backup-mysql.sh --test-email   send a test notification and exit
#   backup-mysql.sh --help         show this help
#
# Configuration is read from the first file found:
#   1. $BACKUP_CONFIG (if set)
#   2. backup.conf next to this script
#   3. /etc/mysql-backup/backup.conf
# See backup.conf.example for every setting.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults (override in backup.conf)
# ---------------------------------------------------------------------------
BACKUP_ROOT="/opt/backupsql/sqlbackup"
CONTAINER_FILTER="mysql"          # extended regex matched against container names
RETENTION_DAYS=30                 # backups older than this may be pruned...
MIN_KEEP=7                        # ...but the newest MIN_KEEP good ones never are
MIN_FREE_MB=1024                  # skip the run if less free space than this
EMAIL_TO=""                       # space-separated; empty disables notifications
EMAIL_FROM=""
EMAIL_SUBJECT_PREFIX="DB Backup"
SENDMAIL_BIN="/usr/sbin/sendmail" # ssmtp or msmtp-mta both provide this
NOTIFY_ON_SUCCESS="yes"           # "no" = only email on failures

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
	log "WARNING: $*" >&2
}

load_config() {
	local candidate
	for candidate in "${BACKUP_CONFIG:-}" "$SCRIPT_DIR/backup.conf" "/etc/mysql-backup/backup.conf"; do
		if [ -n "$candidate" ] && [ -f "$candidate" ]; then
			# shellcheck source=backup.conf.example
			. "$candidate"
			CONFIG_FILE="$candidate"
			return 0
		fi
	done
	CONFIG_FILE=""
	return 0
}

# send_email SUBJECT BODY
# Builds the message itself and hands it to sendmail. Keep BODY short: SMS
# gateways (e.g. tmomail.net) truncate around 160 characters.
send_email() {
	local subject="$EMAIL_SUBJECT_PREFIX $1" body="$2"
	local -a recipients

	read -r -a recipients <<<"$EMAIL_TO"
	if [ "${#recipients[@]}" -eq 0 ]; then
		log "Email disabled (EMAIL_TO is empty); would have sent: $subject"
		return 0
	fi

	if [ ! -x "$SENDMAIL_BIN" ]; then
		warn "$SENDMAIL_BIN not found or not executable; could not send: $subject"
		return 1
	fi

	local to_header
	to_header=$(printf '%s, ' "${recipients[@]}")
	to_header=${to_header%, }

	{
		printf 'To: %s\n' "$to_header"
		[ -n "$EMAIL_FROM" ] && printf 'From: %s\n' "$EMAIL_FROM"
		printf 'Subject: %s\n' "$subject"
		printf 'Date: %s\n' "$(date -R)"
		printf 'MIME-Version: 1.0\n'
		printf 'Content-Type: text/plain; charset=UTF-8\n'
		printf '\n'
		printf '%s\n' "$body"
	} | "$SENDMAIL_BIN" "${recipients[@]}"

	local status=${PIPESTATUS[1]}
	if [ "$status" -ne 0 ]; then
		warn "sendmail exited $status for: $subject"
		return 1
	fi
	log "Sent email: $subject"
}

notify_success() {
	if [ "$NOTIFY_ON_SUCCESS" = "yes" ]; then
		send_email "OK" "$1"
	fi
}

notify_failure() {
	send_email "FAILED" "$1"
}

# verify_backup FILE
# A backup is "good" only if the gzip stream is intact and mysqldump wrote its
# completion marker as the last line.
verify_backup() {
	local file="$1" last_line

	gzip -t "$file" 2>/dev/null || return 1
	# Capture rather than pipe into grep -q: an early-exiting grep would SIGPIPE
	# zcat, which pipefail would report as a failure.
	last_line=$(zcat "$file" | tail -n 1)
	[[ "$last_line" == "-- Dump completed"* ]]
}

# prune_old_backups DIR
# Deletes backups older than RETENTION_DAYS but always keeps the newest
# MIN_KEEP. Prints the number of files deleted.
prune_old_backups() {
	local dir="$1" deleted=0 f
	local -a backups

	# Real backup files only (not the "latest" symlink), newest first
	mapfile -t backups < <(find "$dir" -maxdepth 1 -type f -name 'db_backup_*.sql.gz' \
		-printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)

	if [ "${#backups[@]}" -le "$MIN_KEEP" ]; then
		echo 0
		return 0
	fi

	for f in "${backups[@]:$MIN_KEEP}"; do
		if [ -n "$(find "$f" -maxdepth 0 -mtime +"$RETENTION_DAYS")" ]; then
			rm -f -- "$f" && deleted=$((deleted + 1))
		fi
	done
	echo "$deleted"
}

count_backups() {
	find "$1" -maxdepth 1 -type f -name 'db_backup_*.sql.gz' | wc -l | tr -d ' '
}

free_mb() {
	df -Pm "$1" | awk 'NR==2 {print $4}'
}

# backup_container NAME TIMESTAMP
# Returns 0 on a verified backup, 1 otherwise.
backup_container() {
	local name="$1" timestamp="$2"
	local dir="$BACKUP_ROOT/$name"
	local file="db_backup_${timestamp}.sql.gz"
	local path="$dir/$file"
	local temp="$path.partial"

	mkdir -p "$dir"
	log "Starting backup for container --> $name"

	# The root password comes from the container's own environment (set by
	# compose from .env). Single quotes stop the host shell from expanding it,
	# and MYSQL_PWD keeps it off the command line.
	docker exec "$name" sh -c '
		if [ -z "${MYSQL_ROOT_PASSWORD:-}" ]; then
			echo "MYSQL_ROOT_PASSWORD is not set in this container" >&2
			exit 99
		fi
		MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root \
			--all-databases \
			--single-transaction \
			--quick \
			--routines \
			--events \
			--triggers
	' | gzip >"$temp"

	local -a status=("${PIPESTATUS[@]}")
	local dump_status=${status[0]} gzip_status=${status[1]}

	if [ "$dump_status" -ne 0 ] || [ "$gzip_status" -ne 0 ] || ! verify_backup "$temp"; then
		rm -f -- "$temp"
		log "Backup FAILED for $name (mysqldump=$dump_status, gzip=$gzip_status)"
		notify_failure "$name on $HOST: dump failed (mysqldump=$dump_status gzip=$gzip_status). Old backups kept."
		return 1
	fi

	mv -- "$temp" "$path"
	ln -sfn "$file" "$dir/latest_db_backup.sql.gz"

	# Prune only after a verified backup, and never below MIN_KEEP good copies.
	local deleted kept size
	deleted=$(prune_old_backups "$dir")
	kept=$(count_backups "$dir")
	size=$(du -h "$path" | cut -f1)

	log "Backup OK for $name: $file ($size), kept $kept, pruned $deleted"
	notify_success "$name on $HOST: $file ($size). Kept $kept, pruned $deleted."
	return 0
}

usage() {
	sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	load_config
	HOST=$(hostname)

	case "${1:-}" in
		-h | --help)
			usage
			return 0
			;;
		--test-email)
			log "Config: ${CONFIG_FILE:-<none, using defaults>}"
			send_email "Test" "Test notification from backup-mysql.sh on $HOST."
			return $?
			;;
		"") ;;
		*)
			echo "Unknown option: $1" >&2
			usage >&2
			return 2
			;;
	esac

	log "Config: ${CONFIG_FILE:-<none, using defaults>}"
	mkdir -p "$BACKUP_ROOT" || {
		notify_failure "Cannot create $BACKUP_ROOT on $HOST."
		return 1
	}

	# Only one run at a time (a slow dump must not overlap the next cron run).
	exec 9>"$BACKUP_ROOT/.backup.lock"
	if ! flock -n 9; then
		log "Another backup run is in progress; exiting."
		return 0
	fi

	local free
	free=$(free_mb "$BACKUP_ROOT")
	if [ -n "$free" ] && [ "$free" -lt "$MIN_FREE_MB" ]; then
		log "Only ${free}MB free in $BACKUP_ROOT (need $MIN_FREE_MB); skipping."
		notify_failure "Low disk on $HOST: ${free}MB free in $BACKUP_ROOT. Backup skipped."
		return 1
	fi

	local containers
	containers=$(docker ps --format '{{.Names}}' | grep -E -- "$CONTAINER_FILTER")
	if [ -z "$containers" ]; then
		log "No running containers matching '$CONTAINER_FILTER'."
		notify_failure "No running containers matching '$CONTAINER_FILTER' on $HOST."
		return 1
	fi

	local timestamp failures=0 name
	timestamp=$(date +%Y-%m-%d_%H%M%S)
	for name in $containers; do
		backup_container "$name" "$timestamp" || failures=$((failures + 1))
	done

	# Clean up leftover partial files from interrupted runs
	find "$BACKUP_ROOT" -type f -name '*.sql.gz.partial' -mmin +60 -delete

	log "All matching container backup attempts completed ($failures failed)."
	[ "$failures" -eq 0 ]
}

# Allow tests to source the functions without running anything.
if [ "${BACKUP_LIB_ONLY:-0}" != "1" ]; then
	main "$@"
fi
