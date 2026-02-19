#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# selfsql backup - pg_dump with optional S3 upload
# ──────────────────────────────────────────────

# ── Config ───────────────────────────────────
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/selfsql}"
KEEP_DAYS="${KEEP_DAYS:-7}"

# S3-compatible upload (Backblaze B2, Cloudflare R2, Hetzner, AWS, etc.)
S3_BUCKET="${S3_BUCKET:-}"           # e.g. s3://my-bucket/backups
S3_ENDPOINT="${S3_ENDPOINT:-}"       # e.g. https://s3.us-west-002.backblazeb2.com
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
# ──────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[backup]${NC} $1"; }
warn() { echo -e "${YELLOW}[backup]${NC} $1"; }
err()  { echo -e "${RED}[backup]${NC} $1"; exit 1; }

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DAY_OF_WEEK=$(date +%A)

# ── Resolve DB credentials ──────────────────
if [[ -z "$DB_NAME" || -z "$DB_USER" ]]; then
  # Try to read from the env file if it exists
  ENV_FILE="/etc/selfsql/.env"
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
  else
    err "DB_NAME and DB_USER are required. Set them as env vars or create ${ENV_FILE}"
  fi
fi

[[ -z "$DB_NAME" ]] && err "DB_NAME is required"
[[ -z "$DB_USER" ]] && err "DB_USER is required"

# ── Create backup directory ──────────────────
mkdir -p "$BACKUP_DIR"

# ── Dump ─────────────────────────────────────
FILENAME="${DB_NAME}_${TIMESTAMP}.sql.gz"
FILEPATH="${BACKUP_DIR}/${FILENAME}"

log "Dumping ${DB_NAME}..."
sudo -u postgres pg_dump --no-owner --no-acl "$DB_NAME" | gzip > "$FILEPATH"

SIZE=$(du -h "$FILEPATH" | cut -f1)
log "Created ${FILEPATH} (${SIZE})"

# ── Upload to S3 (if configured) ────────────
if [[ -n "$S3_BUCKET" ]]; then
  if ! command -v aws &> /dev/null; then
    warn "aws CLI not found. Installing..."
    apt-get install -y -qq awscli > /dev/null 2>&1 || {
      err "Failed to install aws CLI. Install it manually: apt install awscli"
    }
  fi

  S3_PATH="${S3_BUCKET%/}/${FILENAME}"
  ENDPOINT_FLAG=""
  [[ -n "$S3_ENDPOINT" ]] && ENDPOINT_FLAG="--endpoint-url ${S3_ENDPOINT}"

  log "Uploading to ${S3_PATH}..."
  aws s3 cp "$FILEPATH" "$S3_PATH" $ENDPOINT_FLAG --quiet
  log "Upload complete"

  # Clean old backups from S3
  log "Cleaning S3 backups older than ${KEEP_DAYS} days..."
  CUTOFF=$(date -d "-${KEEP_DAYS} days" +%Y%m%d 2>/dev/null || date -v-${KEEP_DAYS}d +%Y%m%d)
  aws s3 ls "${S3_BUCKET%/}/" $ENDPOINT_FLAG | while read -r line; do
    file=$(echo "$line" | awk '{print $4}')
    # Extract date from filename: dbname_YYYYMMDD_HHMMSS.sql.gz
    file_date=$(echo "$file" | grep -oP '\d{8}(?=_\d{6})' || true)
    if [[ -n "$file_date" && "$file_date" < "$CUTOFF" ]]; then
      aws s3 rm "${S3_BUCKET%/}/${file}" $ENDPOINT_FLAG --quiet
      log "  Deleted old: ${file}"
    fi
  done
fi

# ── Clean old local backups ──────────────────
log "Cleaning local backups older than ${KEEP_DAYS} days..."
find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz" -mtime +"$KEEP_DAYS" -delete

REMAINING=$(find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz" | wc -l)
log "Done. ${REMAINING} local backup(s) retained."
