#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: root 권한으로 실행하세요.' >&2
  exit 1
fi

TOKEN_FILE='/etc/prometheus/credentials/main-token'
CA_FILE='/etc/prometheus/credentials/main-ca.crt'
DATASOURCE_DIR='/etc/grafana/provisioning/datasources'
DEST="${DATASOURCE_DIR}/loki.yaml"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

[[ -r "$TOKEN_FILE" ]] || { echo "ERROR: $TOKEN_FILE 없음" >&2; exit 2; }
[[ -r "$CA_FILE" ]] || { echo "ERROR: $CA_FILE 없음" >&2; exit 3; }

install -d -o root -g root -m 0755 "$DATASOURCE_DIR"

if [[ -f "$DEST" ]]; then
  cp -a "$DEST" "${DEST}.before-pc6-${TIMESTAMP}"
  chmod 0600 "${DEST}.before-pc6-${TIMESTAMP}"
  echo "DATASOURCE_BACKUP=${DEST}.before-pc6-${TIMESTAMP}"
fi

TMP_FILE=$(mktemp)
chmod 0600 "$TMP_FILE"
trap 'rm -f "$TMP_FILE"' EXIT

{
  cat <<'EOF'
apiVersion: 1

datasources:
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: https://192.168.34.100:6443/api/v1/namespaces/logging/services/loki:3100/proxy
    isDefault: false
    editable: false
    jsonData:
      maxLines: 1000
      httpHeaderName1: Authorization
      tlsAuthWithCACert: true
    secureJsonData:
      tlsCACert: |
EOF
  sed 's/^/        /' "$CA_FILE"
  printf '      httpHeaderValue1: "Bearer '
  tr -d '\r\n' < "$TOKEN_FILE"
  printf '"\n'
} > "$TMP_FILE"

install -o 472 -g 472 -m 0640 "$TMP_FILE" "$DEST"

REFERENCE="${DATASOURCE_DIR}/prometheus.yaml"
if [[ -f "$REFERENCE" ]] && command -v chcon >/dev/null 2>&1; then
  chcon --reference="$REFERENCE" "$DEST" || true
fi

systemctl restart grafana.service

for _ in {1..20}; do
  if curl -fsS --max-time 3 \
    http://192.168.14.73:3000/api/health >/dev/null 2>&1; then
    echo 'GRAFANA_HEALTHY'
    echo 'LOKI_DATASOURCE_CONFIGURED'
    exit 0
  fi
  sleep 2
done

echo 'ERROR: Grafana가 재시작 후 준비되지 않았습니다.' >&2
exit 4
