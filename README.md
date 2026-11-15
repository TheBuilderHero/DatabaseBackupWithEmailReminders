# DatabaseBackupWithEmailReminders

Nightly backups of every running MySQL Docker container, with a text/email
notification after each run.

- Dumps all databases (plus routines, events and triggers) with `mysqldump`,
  gzipped, one folder per container.
- Logs in with the root password the container already has in its
  environment (`MYSQL_ROOT_PASSWORD`), so no password lives in this repo or on
  the command line.
- Checks every dump before keeping it: `gzip -t` must pass and the file must
  end with mysqldump's `-- Dump completed` marker. Partial or broken dumps are
  thrown away and never replace a good one.
- Prunes old backups safely. Backups older than `RETENTION_DAYS` are deleted,
  but the newest `MIN_KEEP` good ones are never deleted, so a month of failures
  still leaves you the last week of good backups. Pruning only runs after a
  successful backup.
- Sends its own email through `sendmail` (ssmtp or msmtp). Messages are kept
  under ~160 characters so SMS gateways like `@tmomail.net` don't cut them off.
- Skips the run and alerts you if the backup disk is low on space, and uses a
  lock so two runs never overlap.

## Files

| File | Purpose |
| --- | --- |
| `backup-mysql.sh` | The backup job (cron runs this) |
| `restore-mysql.sh` | Restore a backup into a container, with a typed confirmation |
| `install.sh` | Server setup: config, cron entry, log rotation |
| `backup.conf.example` | Every setting, documented |
| `tests/run-tests.sh` | Offline tests for pruning, verification and email |

## Server setup

Requirements: `docker`, `gzip`, `flock` (util-linux), and a working
`/usr/sbin/sendmail` (ssmtp, or `msmtp` + `msmtp-mta`) for notifications.

```bash
sudo git clone git@github.com:TheBuilderHero/DatabaseBackupWithEmailReminders.git /opt/DatabaseBackupWithEmailReminders
cd /opt/DatabaseBackupWithEmailReminders
sudo ./install.sh
sudo nano /etc/mysql-backup/backup.conf      # set EMAIL_TO, EMAIL_FROM
sudo ./backup-mysql.sh --test-email
sudo ./backup-mysql.sh                       # one manual run
```

`install.sh` creates:

- `/etc/mysql-backup/backup.conf` (mode 600, only if it doesn't already exist)
- `/etc/cron.d/mysql-backup`, daily at 02:00 by default. Pass
  `--schedule "0 3 * * *"` to change it.
- `/etc/logrotate.d/mysql-backup` for `/var/log/mysql-backup.log`

If the old backup script is still in root's crontab, remove that line
(`sudo crontab -e`) so the two don't both run.

### Updating

```bash
cd /opt/DatabaseBackupWithEmailReminders && sudo git pull
```

Cron runs the script straight from the clone, so a pull is all it takes. Your
config in `/etc/mysql-backup/` is never touched.

## Configuration

See [`backup.conf.example`](backup.conf.example). The main settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| `BACKUP_ROOT` | `/opt/backupsql/sqlbackup` | Where dumps go |
| `CONTAINER_FILTER` | `mysql` | Regex matched against container names |
| `RETENTION_DAYS` | `30` | Age after which backups may be pruned |
| `MIN_KEEP` | `7` | Newest good backups that are never pruned |
| `MIN_FREE_MB` | `1024` | Skip the run below this much free space |
| `EMAIL_TO` | empty | Space-separated recipients; empty disables email |
| `NOTIFY_ON_SUCCESS` | `yes` | `no` = only text on failures |

The config is looked up in this order: `$BACKUP_CONFIG`, `backup.conf` next to
the script, then `/etc/mysql-backup/backup.conf`. `backup.conf` is
git-ignored, so phone numbers stay out of the repo.

## Backups on disk

```
/opt/backupsql/sqlbackup/
  budgetting_online-mysql-1/
    db_backup_2026-11-14_020001.sql.gz
    db_backup_2026-11-15_020001.sql.gz
    latest_db_backup.sql.gz -> db_backup_2026-11-15_020001.sql.gz
```

## Restoring

```bash
sudo ./restore-mysql.sh --list budgetting_online-mysql-1
sudo ./restore-mysql.sh budgetting_online-mysql-1                  # latest
sudo ./restore-mysql.sh budgetting_online-mysql-1 /path/to/db_backup_....sql.gz
```

The dump includes every database, the `mysql` system schema too, so a restore
replaces all of them, including users and passwords as they were at backup
time. You have to type the container name to confirm.

## Troubleshooting

**`Access denied for user 'root'@'localhost'`.** The password in the container
doesn't match the database. MySQL only reads `MYSQL_ROOT_PASSWORD` the first
time it creates its data volume, so if `.env` changed later the two drift
apart. Check with:

```bash
docker exec <container> sh -c 'MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysqladmin -uroot status'
```

**No texts arriving.** Run `./backup-mysql.sh --test-email` and check the
output. sSMTP rewrites the `From:` header unless `/etc/ssmtp/ssmtp.conf` has
`FromLineOverride=YES`. Gmail needs an app password.

**Logs.** `tail -n 50 /var/log/mysql-backup.log`

## Tests

The tests use fake files and a fake `sendmail`, so they need no Docker or
MySQL:

```bash
bash tests/run-tests.sh
```
