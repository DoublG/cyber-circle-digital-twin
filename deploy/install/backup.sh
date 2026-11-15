#!/usr/bin/env bash
# The database dump (cybercircle-backup.service): BACKUP_DIR/cybercircle-YYYY-MM-DD.sql.gz,
# older than BACKUP_KEEP_DAYS days removed (pg_dump, plain SQL).  Restore, into an empty database:
#   sudo systemctl stop cybercircle-control
#   sudo -u postgres dropdb cybercircle && sudo -u postgres createdb -O cybercircle cybercircle
#   gunzip -c cybercircle-2026-11-03.sql.gz | sudo -u postgres psql -q -v ON_ERROR_STOP=1 cybercircle >/dev/null
#   sudo systemctl start cybercircle-control
set -euo pipefail
ENV_FILE=${CC_ENV_FILE:-/etc/cybercircle/cybercircle.env}
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
dir=${BACKUP_DIR:-/var/backups/cybercircle}
mkdir -p "$dir"
out="$dir/cybercircle-$(date +%F).sql.gz"
PGPASSWORD="$DB_PASSWORD" pg_dump --no-owner --no-privileges -h "${DB_HOST:-localhost}" -p "${DB_PORT:-5432}" \
    -U "$DB_USER" "$DB_NAME" | gzip > "$out.tmp"
mv "$out.tmp" "$out"
find "$dir" -name 'cybercircle-*.sql.gz' -mtime +"${BACKUP_KEEP_DAYS:-30}" -delete
echo "backup: $out ($(du -h "$out" | cut -f1))"
