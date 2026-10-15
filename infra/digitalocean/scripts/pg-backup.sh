#!/usr/bin/env bash
# DAXA PostgreSQL backup: dump -> encrypt (age, public key only) -> upload to
# DigitalOcean Spaces in another region. A short local copy is kept on the data
# volume for quick restores. Driven by daxa-pg-backup.timer.
set -euo pipefail
umask 077

ENV_FILE="${DAXA_BACKUP_ENV:-/etc/daxa/backup.env}"
# shellcheck source=/dev/null
. "$ENV_FILE"

: "${PG_CONTAINER:?}" "${PG_SUPERUSER:?}" "${BACKUP_LOCAL_DIR:?}" "${AGE_RECIPIENT:?}"
: "${SPACES_REGION:?}" "${SPACES_BUCKET:?}" "${SPACES_ACCESS_KEY_ID:?}" "${SPACES_SECRET_ACCESS_KEY:?}"
SPACES_PREFIX="${SPACES_PREFIX:-postgres}"
BACKUP_LOCAL_RETENTION_DAYS="${BACKUP_LOCAL_RETENTION_DAYS:-3}"

ping_hc() {
  [ -n "${HEALTHCHECK_URL:-}" ] && curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}$1" >/dev/null || true
}
trap 'ping_hc /fail' ERR

# rclone remote defined purely through environment (no config file on disk).
export RCLONE_CONFIG_SPACES_TYPE=s3
export RCLONE_CONFIG_SPACES_PROVIDER=DigitalOcean
export RCLONE_CONFIG_SPACES_ENDPOINT="${SPACES_REGION}.digitaloceanspaces.com"
export RCLONE_CONFIG_SPACES_ACCESS_KEY_ID="$SPACES_ACCESS_KEY_ID"
export RCLONE_CONFIG_SPACES_SECRET_ACCESS_KEY="$SPACES_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_SPACES_ACL=private

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOST="$(hostname -s)"
WORK="${BACKUP_LOCAL_DIR}/${STAMP}"
mkdir -p "$WORK"

psql_q() { docker exec "$PG_CONTAINER" psql -U "$PG_SUPERUSER" -d postgres -Atqc "$1"; }

echo "[$(date -Is)] backup start -> $WORK"

# Roles, grants, tablespaces
docker exec "$PG_CONTAINER" pg_dumpall -U "$PG_SUPERUSER" --globals-only \
  | age -r "$AGE_RECIPIENT" -o "$WORK/globals.sql.age"

# Each database in custom format (compressed, selective restore possible)
for db in $(psql_q "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1"); do
  echo "  dumping $db"
  docker exec "$PG_CONTAINER" pg_dump -U "$PG_SUPERUSER" -Fc -Z 6 "$db" \
    | age -r "$AGE_RECIPIENT" -o "$WORK/${db}.dump.age"
done

( cd "$WORK" && sha256sum ./*.age > SHA256SUMS )

DEST="spaces:${SPACES_BUCKET}/${SPACES_PREFIX}/${HOST}/${STAMP}"
rclone copy "$WORK" "$DEST" --s3-no-check-bucket --retries 5 --low-level-retries 10
rclone check "$WORK" "$DEST" --one-way --s3-no-check-bucket

# Prune local copies (off-server retention is handled by the bucket lifecycle rule)
find "$BACKUP_LOCAL_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+${BACKUP_LOCAL_RETENTION_DAYS}" -exec rm -rf {} +

echo "[$(date -Is)] backup OK -> $DEST"
ping_hc ""
