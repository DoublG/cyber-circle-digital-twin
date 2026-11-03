#!/usr/bin/env bash
# The database dump (cybercircle-backup.service): BACKUP_DIR/cybercircle-YYYY-MM-DD.sql.gz,
# older than BACKUP_KEEP_DAYS days removed.  Restore:
#   gunzip -c cybercircle-2026-11-03.sql.gz | sudo mysql cybercircle
set -euo pipefail
ENV_FILE=${CC_ENV_FILE:-/etc/cybercircle/cybercircle.env}
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
dir=${BACKUP_DIR:-/var/backups/cybercircle}
mkdir -p "$dir"
out="$dir/cybercircle-$(date +%F).sql.gz"
MYSQL_PWD="$DB_PASSWORD" mysqldump --single-transaction -h "${DB_HOST:-localhost}" -u "$DB_USER" "$DB_NAME" | gzip > "$out.tmp"
mv "$out.tmp" "$out"
find "$dir" -name 'cybercircle-*.sql.gz' -mtime +"${BACKUP_KEEP_DAYS:-30}" -delete
echo "backup: $out ($(du -h "$out" | cut -f1))"
