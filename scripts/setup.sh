#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# selfsql - PostgreSQL setup for Hetzner VPS
# Tested on Ubuntu 22.04 / 24.04 (Debian works too)
# Safe to re-run — all steps are idempotent.
# ──────────────────────────────────────────────

# ── Config (change these) ────────────────────
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
ALLOW_IPS="${ALLOW_IPS:-}"  # comma-separated, e.g. "1.2.3.4,5.6.7.8"
PG_PORT="${PG_PORT:-5432}"
# ──────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[selfsql]${NC} $1"; }
warn() { echo -e "${YELLOW}[selfsql]${NC} $1"; }
err()  { echo -e "${RED}[selfsql]${NC} $1"; exit 1; }

# ── Pre-flight checks ────────────────────────
[[ $EUID -ne 0 ]] && err "Run as root: sudo bash setup.sh"

if [[ -z "$DB_USER" ]]; then
  read -rp "Enter DB username: " DB_USER
  [[ -z "$DB_USER" ]] && err "Username cannot be empty"
fi

if [[ -z "$DB_NAME" ]]; then
  read -rp "Enter DB name [${DB_USER}db]: " DB_NAME
  DB_NAME="${DB_NAME:-${DB_USER}db}"
fi

if [[ -z "$DB_PASSWORD" ]]; then
  read -rsp "Enter password for DB user '${DB_USER}': " DB_PASSWORD
  echo
  [[ -z "$DB_PASSWORD" ]] && err "Password cannot be empty"
fi

if [[ -z "$ALLOW_IPS" ]]; then
  echo ""
  warn "No ALLOW_IPS set. Who should be able to connect?"
  echo "  Enter comma-separated IPs (e.g. 1.2.3.4,5.6.7.8)"
  echo "  Or enter 'all' to allow any IP (less secure)"
  read -rp "> " ALLOW_IPS
  [[ -z "$ALLOW_IPS" ]] && err "You must specify at least one IP or 'all'"
fi

# ── Install PostgreSQL ───────────────────────
if command -v psql &> /dev/null && pg_lsclusters -h | grep -q .; then
  log "PostgreSQL already installed, skipping install"
else
  log "Updating packages..."
  apt-get update -qq

  log "Installing PostgreSQL..."
  apt-get install -y -qq postgresql postgresql-contrib ufw > /dev/null
fi

# Ensure UFW is installed even if Postgres was already present
dpkg -s ufw &> /dev/null || apt-get install -y -qq ufw > /dev/null

# Detect the active cluster version (not just the first listed)
PG_VERSION=$(sudo -u postgres psql -t -c "SHOW server_version;" 2>/dev/null | xargs | cut -d. -f1)
if [[ -z "$PG_VERSION" ]]; then
  # Fallback: pick the newest installed version
  PG_VERSION=$(pg_lsclusters -h | awk '{print $1}' | sort -rn | head -1)
fi
PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

log "Detected PostgreSQL version: ${PG_VERSION}"
log "Config: ${PG_CONF}"
log "HBA:    ${PG_HBA}"

# ── Create user and database ─────────────────
log "Creating database '${DB_NAME}' and user '${DB_USER}'..."
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE "${DB_USER}" WITH LOGIN PASSWORD '${DB_PASSWORD}';
  ELSE
    ALTER ROLE "${DB_USER}" WITH PASSWORD '${DB_PASSWORD}';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE "${DB_NAME}" OWNER "${DB_USER}"'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')
\gexec

GRANT ALL PRIVILEGES ON DATABASE "${DB_NAME}" TO "${DB_USER}";
SQL

# ── Configure PostgreSQL to listen externally ─
log "Configuring PostgreSQL to listen on all interfaces..."

# Remove any previous selfsql-managed config and original commented/uncommented lines
sed -i '/# selfsql-conf$/d' "$PG_CONF"
sed -i '/^[[:space:]]*#*[[:space:]]*listen_addresses\s*=/d' "$PG_CONF"
sed -i '/^[[:space:]]*#*[[:space:]]*port\s*=/d' "$PG_CONF"
sed -i '/^[[:space:]]*#*[[:space:]]*password_encryption\s*=/d' "$PG_CONF"

echo "listen_addresses = '*' # selfsql-conf" >> "$PG_CONF"
echo "port = ${PG_PORT} # selfsql-conf" >> "$PG_CONF"
echo "password_encryption = scram-sha-256 # selfsql-conf" >> "$PG_CONF"

# ── SSL with self-signed cert ────────────────
SSL_DIR="/etc/postgresql/${PG_VERSION}/main/ssl"
log "Setting up SSL..."
mkdir -p "$SSL_DIR"

if [[ ! -f "$SSL_DIR/server.key" ]]; then
  openssl req -new -x509 -days 3650 -nodes \
    -out "$SSL_DIR/server.crt" \
    -keyout "$SSL_DIR/server.key" \
    -subj "/CN=$(hostname -f)" \
    2>/dev/null
  chown postgres:postgres "$SSL_DIR/server.key" "$SSL_DIR/server.crt"
  chmod 600 "$SSL_DIR/server.key"
  chmod 644 "$SSL_DIR/server.crt"
fi

sed -i '/# selfsql-ssl$/d' "$PG_CONF"
sed -i '/^[[:space:]]*#*[[:space:]]*ssl\s*=/d' "$PG_CONF"
sed -i '/^[[:space:]]*#*[[:space:]]*ssl_cert_file\s*=/d' "$PG_CONF"
sed -i '/^[[:space:]]*#*[[:space:]]*ssl_key_file\s*=/d' "$PG_CONF"

echo "ssl = on # selfsql-ssl" >> "$PG_CONF"
echo "ssl_cert_file = '${SSL_DIR}/server.crt' # selfsql-ssl" >> "$PG_CONF"
echo "ssl_key_file = '${SSL_DIR}/server.key' # selfsql-ssl" >> "$PG_CONF"

# ── Configure pg_hba.conf ────────────────────
log "Configuring client authentication (pg_hba.conf)..."

# Remove any previous selfsql entries
sed -i '/# selfsql$/d' "$PG_HBA"

if [[ "$ALLOW_IPS" == "all" ]]; then
  echo "hostssl ${DB_NAME} ${DB_USER} 0.0.0.0/0 scram-sha-256 # selfsql" >> "$PG_HBA"
  echo "hostssl ${DB_NAME} ${DB_USER} ::/0      scram-sha-256 # selfsql" >> "$PG_HBA"
  warn "Allowing connections from ANY IP (use a strong password!)"
else
  IFS=',' read -ra IPS <<< "$ALLOW_IPS"
  for ip in "${IPS[@]}"; do
    ip=$(echo "$ip" | xargs)  # trim whitespace
    # Add /32 if no CIDR notation
    [[ "$ip" != *"/"* ]] && ip="${ip}/32"
    echo "hostssl ${DB_NAME} ${DB_USER} ${ip} scram-sha-256 # selfsql" >> "$PG_HBA"
    log "  Allowed: ${ip}"
  done
fi

# ── Firewall (UFW) ───────────────────────────
log "Configuring firewall..."

ufw --force enable > /dev/null 2>&1
ufw allow OpenSSH > /dev/null 2>&1

# Clean old selfsql UFW rules for this port
while ufw status numbered | grep -q "${PG_PORT}/tcp"; do
  RULE_NUM=$(ufw status numbered | grep "${PG_PORT}/tcp" | head -1 | sed 's/.*\[\s*//' | sed 's/\].*//' | xargs)
  [[ -z "$RULE_NUM" ]] && break
  yes | ufw delete "$RULE_NUM" > /dev/null 2>&1 || break
done

if [[ "$ALLOW_IPS" == "all" ]]; then
  ufw allow "$PG_PORT/tcp" > /dev/null 2>&1
  warn "Firewall: port ${PG_PORT} open to all"
else
  IFS=',' read -ra IPS <<< "$ALLOW_IPS"
  for ip in "${IPS[@]}"; do
    ip=$(echo "$ip" | xargs)
    [[ "$ip" == *"/"* ]] || ip="${ip}/32"
    ufw allow from "$ip" to any port "$PG_PORT" proto tcp > /dev/null 2>&1
    log "  Firewall: allowed ${ip} -> port ${PG_PORT}"
  done
fi

# ── Restart PostgreSQL ───────────────────────
log "Restarting PostgreSQL..."
systemctl restart postgresql
systemctl enable postgresql > /dev/null 2>&1

# ── Verify ───────────────────────────────────
if systemctl is-active --quiet postgresql; then
  log "PostgreSQL is running"
else
  err "PostgreSQL failed to start. Check: journalctl -xeu postgresql"
fi

# Verify it's listening on all interfaces, not just localhost
sleep 1
if ss -tlnp | grep -q "0.0.0.0:${PG_PORT}"; then
  log "Listening on 0.0.0.0:${PG_PORT}"
else
  warn "PostgreSQL may not be listening externally. Current listeners:"
  ss -tlnp | grep "$PG_PORT"
  err "Check ${PG_CONF} — listen_addresses may not have applied"
fi

# ── Print connection info ────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN} selfsql setup complete${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo -e " Connection string:"
echo -e "   ${YELLOW}postgresql://${DB_USER}:${DB_PASSWORD}@${SERVER_IP}:${PG_PORT}/${DB_NAME}?sslmode=require${NC}"
echo ""
echo -e " Quick test from your machine:"
echo -e "   psql \"postgresql://${DB_USER}:${DB_PASSWORD}@${SERVER_IP}:${PG_PORT}/${DB_NAME}?sslmode=require\""
echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
