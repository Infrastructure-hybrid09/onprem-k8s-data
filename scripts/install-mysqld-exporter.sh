#!/usr/bin/env bash
set -Eeuo pipefail

EXPORTER_VERSION="0.19.0"
EXPORTER_SHA256="97238be558bd1a6aa6b9a927fa21d91dc5cabe6b9e00678b5cafa2bbb3899e72"
EXPORTER_USER="mysqld_exporter"
EXPORTER_GROUP="mysqld_exporter"
EXPORTER_DB_USER="ir_exporter"
MYSQL_SOCKET="/var/lib/mysql/mysql.sock"

case "$(hostname -s)" in
  db-primary)
    DB_DATA_IP="192.168.44.51"
    ;;
  db-replica)
    DB_DATA_IP="192.168.44.52"
    ;;
  *)
    echo "ERROR: This script must run on db-primary or db-replica." >&2
    echo "Current hostname: $(hostname -s)" >&2
    exit 1
    ;;
esac

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "ERROR: Unsupported architecture: $(uname -m)" >&2
  exit 1
fi

for command_name in curl tar sha256sum sudo mariadb systemctl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $command_name" >&2
    exit 1
  fi
done

if ! sudo -v; then
  echo "ERROR: sudo authentication failed." >&2
  exit 1
fi

if ! command -v setfacl >/dev/null 2>&1; then
  echo "Installing the ACL utility required for least-privilege socket access."
  sudo dnf install -y acl
fi

if [[ "$(sudo systemctl is-active mariadb || true)" != "active" ]]; then
  echo "ERROR: MariaDB is not active." >&2
  exit 1
fi

ACCOUNT_COUNT="$(
  sudo mariadb --protocol=socket -Nse \
    "SELECT COUNT(*) FROM mysql.user WHERE User='${EXPORTER_DB_USER}' AND Host='localhost';"
)"
if [[ "$ACCOUNT_COUNT" != "1" ]]; then
  echo "ERROR: ${EXPORTER_DB_USER}@localhost does not exist on this DB." >&2
  exit 1
fi

read -r -s -p "Password for ${EXPORTER_DB_USER}@localhost: " EXPORTER_DB_PASSWORD
echo
if [[ -z "$EXPORTER_DB_PASSWORD" ]]; then
  echo "ERROR: Password cannot be empty." >&2
  exit 1
fi

escape_option_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

ESCAPED_DB_PASSWORD="$(escape_option_value "$EXPORTER_DB_PASSWORD")"
unset EXPORTER_DB_PASSWORD

WORK_DIR="$(mktemp -d /tmp/mysqld-exporter-install.XXXXXX)"
cleanup() {
  unset ESCAPED_DB_PASSWORD
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
umask 077

ARCHIVE="mysqld_exporter-${EXPORTER_VERSION}.linux-amd64.tar.gz"
DOWNLOAD_URL="https://github.com/prometheus/mysqld_exporter/releases/download/v${EXPORTER_VERSION}/${ARCHIVE}"

echo "[1/7] Downloading mysqld_exporter ${EXPORTER_VERSION}"
curl --fail --location --show-error \
  --output "${WORK_DIR}/${ARCHIVE}" \
  "$DOWNLOAD_URL"

echo "[2/7] Verifying SHA256"
printf '%s  %s\n' "$EXPORTER_SHA256" "${WORK_DIR}/${ARCHIVE}" \
  | sha256sum --check -

echo "[3/7] Installing binary and service account"
tar -xzf "${WORK_DIR}/${ARCHIVE}" -C "$WORK_DIR"

if ! getent passwd "$EXPORTER_USER" >/dev/null 2>&1; then
  sudo useradd \
    --system \
    --no-create-home \
    --shell /sbin/nologin \
    "$EXPORTER_USER"
fi

sudo install \
  -o root \
  -g root \
  -m 0755 \
  "${WORK_DIR}/mysqld_exporter-${EXPORTER_VERSION}.linux-amd64/mysqld_exporter" \
  /usr/local/bin/mysqld_exporter

echo "[4/7] Writing protected DB client configuration"
install -m 0600 /dev/null "${WORK_DIR}/my.cnf"
printf '[client]\nuser=%s\npassword="%s"\nhost=localhost\nprotocol=socket\nsocket=%s\n' \
  "$EXPORTER_DB_USER" \
  "$ESCAPED_DB_PASSWORD" \
  "$MYSQL_SOCKET" \
  >"${WORK_DIR}/my.cnf"

sudo install \
  -d \
  -o root \
  -g "$EXPORTER_GROUP" \
  -m 0750 \
  /etc/mysqld_exporter

if sudo test -f /etc/mysqld_exporter/my.cnf; then
  sudo cp -a \
    /etc/mysqld_exporter/my.cnf \
    "/etc/mysqld_exporter/my.cnf.before-$(date +%Y%m%d-%H%M%S)"
fi

sudo install \
  -o root \
  -g "$EXPORTER_GROUP" \
  -m 0640 \
  "${WORK_DIR}/my.cnf" \
  /etc/mysqld_exporter/my.cnf

echo "[5/7] Testing DB credentials as the exporter service account"
MYSQL_SOCKET_DIR="$(dirname -- "$MYSQL_SOCKET")"
sudo setfacl -m "u:${EXPORTER_USER}:--x" "$MYSQL_SOCKET_DIR"

if ! sudo -u "$EXPORTER_USER" test -S "$MYSQL_SOCKET"; then
  echo "ERROR: ${EXPORTER_USER} cannot access the MariaDB socket path." >&2
  sudo namei -l "$MYSQL_SOCKET" >&2 || true
  sudo getfacl -p "$MYSQL_SOCKET_DIR" >&2 || true
  exit 1
fi

sudo -u "$EXPORTER_USER" mariadb \
  --defaults-extra-file=/etc/mysqld_exporter/my.cnf \
  --batch \
  --skip-column-names \
  --execute='SELECT CURRENT_USER();'

echo "[6/7] Installing and starting systemd service"
cat >"${WORK_DIR}/mysqld_exporter.service" <<EOF
[Unit]
Description=Prometheus MariaDB Exporter
Wants=network-online.target
After=network-online.target mariadb.service

[Service]
Type=simple
User=${EXPORTER_USER}
Group=${EXPORTER_GROUP}
ExecStart=/usr/local/bin/mysqld_exporter --config.my-cnf=/etc/mysqld_exporter/my.cnf --web.listen-address=${DB_DATA_IP}:9104
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo install \
  -o root \
  -g root \
  -m 0644 \
  "${WORK_DIR}/mysqld_exporter.service" \
  /etc/systemd/system/mysqld_exporter.service

sudo restorecon \
  /usr/local/bin/mysqld_exporter \
  /etc/mysqld_exporter/my.cnf \
  /etc/systemd/system/mysqld_exporter.service \
  >/dev/null 2>&1 || true

sudo systemctl daemon-reload
sudo systemctl enable mysqld_exporter >/dev/null
sudo systemctl restart mysqld_exporter

echo "[7/7] Verifying service and metrics"
for attempt in {1..10}; do
  if curl --fail --silent "http://${DB_DATA_IP}:9104/metrics" \
    | grep -q '^mysql_up 1$'; then
    break
  fi

  if [[ "$attempt" == "10" ]]; then
    echo "ERROR: mysql_up did not become 1." >&2
    sudo systemctl status mysqld_exporter --no-pager >&2 || true
    sudo journalctl -u mysqld_exporter -n 100 --no-pager >&2 || true
    exit 1
  fi
  sleep 2
done

sudo systemctl is-enabled mysqld_exporter
sudo systemctl is-active mysqld_exporter
sudo ss -lntp | grep ':9104'
curl --silent "http://${DB_DATA_IP}:9104/metrics" | grep '^mysql_up'

echo "SUCCESS: mysqld_exporter is running on ${DB_DATA_IP}:9104."
