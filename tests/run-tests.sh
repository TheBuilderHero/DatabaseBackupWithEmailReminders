#!/usr/bin/env bash
#
# Offline tests for backup-mysql.sh. No Docker or MySQL needed: they use fake
# backup files and a fake sendmail.
#
#   bash tests/run-tests.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_LIB_ONLY=1 . "$REPO_DIR/backup-mysql.sh"
set +e

PASS=0
FAIL=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
HOST="testhost"

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { # check DESCRIPTION EXPECTED ACTUAL
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# make_backup DIR NAME DAYS_OLD
make_backup() {
	printf 'CREATE TABLE t (id int);\n-- Dump completed on 2026-11-14\n' | gzip >"$1/$2"
	touch -d "$3 days ago" "$1/$2"
}

# new_dir NAME -> prints a fresh directory path
new_dir() {
	local d="$WORK/$1"
	rm -rf "$d"
	mkdir -p "$d"
	echo "$d"
}

remaining() { find "$1" -maxdepth 1 -type f -name 'db_backup_*.sql.gz' | wc -l | tr -d ' '; }

echo "prune_old_backups"
RETENTION_DAYS=30
MIN_KEEP=7

d=$(new_dir all-old)
for i in $(seq 1 10); do make_backup "$d" "db_backup_$i.sql.gz" $((40 + i)); done
check "10 old backups: prunes 3" 3 "$(prune_old_backups "$d")"
check "10 old backups: keeps 7" 7 "$(remaining "$d")"
for i in 1 2 3 4 5 6 7; do
	[ -f "$d/db_backup_$i.sql.gz" ] || bad "newest backup db_backup_$i was deleted"
done
ok "the 7 kept are the newest 7"

d=$(new_dir few-old)
for i in 1 2 3 4 5; do make_backup "$d" "db_backup_$i.sql.gz" 90; done
check "5 old backups (< MIN_KEEP): prunes none" 0 "$(prune_old_backups "$d")"
check "5 old backups: keeps all 5" 5 "$(remaining "$d")"

d=$(new_dir mixed)
for i in 1 2 3; do make_backup "$d" "db_backup_new$i.sql.gz" "$i"; done
for i in $(seq 1 7); do make_backup "$d" "db_backup_old$i.sql.gz" $((40 + i)); done
check "3 recent + 7 old: prunes 3 oldest" 3 "$(prune_old_backups "$d")"
check "3 recent + 7 old: keeps 7" 7 "$(remaining "$d")"
[ ! -f "$d/db_backup_old7.sql.gz" ] && [ -f "$d/db_backup_old4.sql.gz" ] &&
	ok "deleted the oldest, kept old1-old4" || bad "wrong files deleted in mixed set"

d=$(new_dir all-recent)
for i in $(seq 1 20); do make_backup "$d" "db_backup_$i.sql.gz" "$i"; done
check "20 backups within retention: prunes none" 0 "$(prune_old_backups "$d")"

d=$(new_dir symlink)
for i in $(seq 1 7); do make_backup "$d" "db_backup_$i.sql.gz" 50; done
ln -s db_backup_1.sql.gz "$d/latest_db_backup.sql.gz"
make_backup "$d" "other_file.sql.gz" 90
check "symlink and non-matching files ignored" 0 "$(prune_old_backups "$d")"
[ -f "$d/other_file.sql.gz" ] && ok "non-backup file untouched" || bad "non-backup file deleted"

echo "verify_backup"
d=$(new_dir verify)
make_backup "$d" good.sql.gz 0
verify_backup "$d/good.sql.gz" && ok "complete dump passes" || bad "complete dump rejected"

printf 'CREATE TABLE t (id int);\nINSERT INTO t VALUES (1' | gzip >"$d/truncated.sql.gz"
verify_backup "$d/truncated.sql.gz" && bad "truncated dump accepted" || ok "dump without completion marker fails"

printf 'not gzip at all' >"$d/corrupt.sql.gz"
verify_backup "$d/corrupt.sql.gz" && bad "corrupt gzip accepted" || ok "corrupt gzip fails"

: | gzip >"$d/empty.sql.gz"
verify_backup "$d/empty.sql.gz" && bad "empty dump accepted" || ok "empty dump fails"

echo "send_email"
FAKE_SENDMAIL="$WORK/sendmail"
cat >"$FAKE_SENDMAIL" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$WORK/sendmail.args"
cat >"$WORK/sendmail.msg"
EOF
chmod +x "$FAKE_SENDMAIL"
SENDMAIL_BIN="$FAKE_SENDMAIL"
EMAIL_FROM="sender@example.com"
EMAIL_SUBJECT_PREFIX="DB Backup"

EMAIL_TO="a@example.com b@example.com"
send_email "OK" "hello body" >/dev/null
check "passes each recipient to sendmail" "a@example.com b@example.com" "$(tr '\n' ' ' <"$WORK/sendmail.args" | sed 's/ $//')"
grep -qx 'To: a@example.com, b@example.com' "$WORK/sendmail.msg" && ok "To header lists all recipients" || bad "To header wrong"
grep -qx 'Subject: DB Backup OK' "$WORK/sendmail.msg" && ok "Subject has prefix" || bad "Subject wrong"
grep -qx 'From: sender@example.com' "$WORK/sendmail.msg" && ok "From header set" || bad "From header missing"
grep -qx 'hello body' "$WORK/sendmail.msg" && ok "body included" || bad "body missing"
# Headers end at the first blank line, and the body comes after it
awk 'NF==0{blank=1; next} blank && /hello body/ {found=1} END{exit !found}' "$WORK/sendmail.msg" &&
	ok "blank line separates headers from body" || bad "no header/body separator"

rm -f "$WORK/sendmail.msg"
EMAIL_TO=""
send_email "OK" "should not send" >/dev/null
[ ! -f "$WORK/sendmail.msg" ] && ok "empty EMAIL_TO sends nothing" || bad "sent with empty EMAIL_TO"

EMAIL_TO="a@example.com"
NOTIFY_ON_SUCCESS="no"
notify_success "quiet" >/dev/null
[ ! -f "$WORK/sendmail.msg" ] && ok "NOTIFY_ON_SUCCESS=no suppresses success email" || bad "success email sent anyway"
notify_failure "loud" >/dev/null
grep -qx 'Subject: DB Backup FAILED' "$WORK/sendmail.msg" && ok "failures still email when NOTIFY_ON_SUCCESS=no" || bad "failure email missing"

SENDMAIL_BIN="$WORK/does-not-exist"
send_email "OK" "x" >/dev/null 2>&1 && bad "missing sendmail reported success" || ok "missing sendmail returns an error"

printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 1\n' >"$WORK/failing-sendmail"
chmod +x "$WORK/failing-sendmail"
SENDMAIL_BIN="$WORK/failing-sendmail"
send_email "OK" "x" >/dev/null 2>&1 && bad "failing sendmail reported success" || ok "failing sendmail returns an error"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
