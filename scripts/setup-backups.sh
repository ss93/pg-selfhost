#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# selfsql - backup cron installer
# ──────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[selfsql]${NC} $1"; }
warn() { echo -e "${YELLOW}[selfsql]${NC} $1"; }
err()  { echo -e "${RED}[selfsql]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Run as root: sudo bash setup-backups.sh"

# ── Collect info ─────────────────────────────
read -rp "DB name: " DB_NAME
[[ -z "$DB_NAME" ]] && err "DB name cannot be empty"

read -rp "DB user: " DB_USER
[[ -z "$DB_USER" ]] && err "DB user cannot be empty"

read -rp "Backup directory [/var/backups/selfsql]: " BACKUP_DIR
BACKUP_DIR="${BACKUP_DIR:-/var/backups/selfsql}"

read -rp "Keep backups for how many days? [7]: " KEEP_DAYS
KEEP_DAYS="${KEEP_DAYS:-7}"

read -rp "Backup schedule - hour (0-23) [3]: " CRON_HOUR
CRON_HOUR="${CRON_HOUR:-3}"

# ── S3 setup (optional) ─────────────────────
echo ""
read -rp "Upload to S3-compatible storage? (y/n) [n]: " USE_S3
S3_BUCKET=""
S3_ENDPOINT=""
AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""

if [[ "$USE_S3" =~ ^[Yy] ]]; then
  read -rp "S3 bucket (e.g. s3://my-bucket/backups): " S3_BUCKET
  [[ -z "$S3_BUCKET" ]] && err "Bucket cannot be empty"

  read -rp "S3 endpoint URL (leave empty for AWS): " S3_ENDPOINT
  read -rp "Access key ID: " AWS_ACCESS_KEY_ID
  read -rsp "Secret access key: " AWS_SECRET_ACCESS_KEY
  echo

  # Install aws CLI if needed
  if ! command -v aws &> /dev/null; then
    log "Installing aws CLI..."
    apt-get install -y -qq awscli > /dev/null
  fi
fi

# ── Save env file ────────────────────────────
ENV_DIR="/etc/selfsql"
ENV_FILE="${ENV_DIR}/.env"

mkdir -p "$ENV_DIR"
cat > "$ENV_FILE" <<EOF
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
BACKUP_DIR="${BACKUP_DIR}"
KEEP_DAYS="${KEEP_DAYS}"
S3_BUCKET="${S3_BUCKET}"
S3_ENDPOINT="${S3_ENDPOINT}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
EOF

chmod 600 "$ENV_FILE"
log "Saved config to ${ENV_FILE}"

# ── Install backup script ───────────────────
SCRIPT_DIR="/opt/selfsql"
mkdir -p "$SCRIPT_DIR"

SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/backup.sh"
if [[ -f "$SCRIPT_SRC" ]]; then
  cp "$SCRIPT_SRC" "${SCRIPT_DIR}/backup.sh"
else
  err "backup.sh not found next to this script"
fi
chmod +x "${SCRIPT_DIR}/backup.sh"
log "Installed backup script to ${SCRIPT_DIR}/backup.sh"

# ── Create backup directory ──────────────────
mkdir -p "$BACKUP_DIR"

# ── Set up cron ──────────────────────────────
CRON_LINE="0 ${CRON_HOUR} * * * /opt/selfsql/backup.sh >> /var/log/selfsql-backup.log 2>&1"

# Remove any existing selfsql cron entries
crontab -l 2>/dev/null | grep -v '/opt/selfsql/backup.sh' | crontab - 2>/dev/null || true

# Add new entry
(crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
log "Cron job installed: daily at ${CRON_HOUR}:00"

# ── Test run ─────────────────────────────────
echo ""
read -rp "Run a test backup now? (y/n) [y]: " TEST_NOW
if [[ "${TEST_NOW:-y}" =~ ^[Yy] ]]; then
  log "Running test backup..."
  bash "${SCRIPT_DIR}/backup.sh"
  log "Test backup complete"
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN} Backups configured${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo -e " Schedule:  Daily at ${CRON_HOUR}:00"
echo -e " Local dir: ${BACKUP_DIR}"
echo -e " Retention: ${KEEP_DAYS} days"
[[ -n "$S3_BUCKET" ]] && echo -e " S3 upload: ${S3_BUCKET}"
echo -e " Logs:      /var/log/selfsql-backup.log"
echo ""
echo -e " Manual backup:  ${YELLOW}bash /opt/selfsql/backup.sh${NC}"
echo -e " Manual restore: ${YELLOW}gunzip -c /path/to/backup.sql.gz | psql -U ${DB_USER} ${DB_NAME}${NC}"
echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
