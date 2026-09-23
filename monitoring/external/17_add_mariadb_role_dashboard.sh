#!/usr/bin/env bash
set -Eeuo pipefail

DASHBOARD='/var/lib/grafana/dashboards/observability-platform.json'
PROMETHEUS_URL='http://127.0.0.1:9090'
GRAFANA_HEALTH_URL='http://192.168.14.73:3000/api/health'
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="${DASHBOARD}.before-mariadb-role-${STAMP}"
TEMP_FILE=$(mktemp /tmp/observability-mariadb-role.XXXXXX.json)

cleanup() {
  rm -f -- "$TEMP_FILE"
}
trap cleanup EXIT

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

for command_name in curl jq systemctl; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command not found: ${command_name}" >&2
    exit 2
  }
done

[[ -s "$DASHBOARD" ]] || {
  echo "ERROR: 대시보드 파일이 없습니다: ${DASHBOARD}" >&2
  exit 3
}

echo '[1/4] MariaDB Primary/Replica 역할 메트릭을 확인합니다.'
ROLE_JSON=$(curl -fsSG "${PROMETHEUS_URL}/api/v1/query" \
  --data-urlencode 'query=mysql_global_variables_read_only{job="mariadb"}')

metric_count=$(jq -r '.data.result | length' <<<"$ROLE_JSON")
primary_count=$(jq -r '[.data.result[] | select(.value[1] == "0")] | length' <<<"$ROLE_JSON")
replica_count=$(jq -r '[.data.result[] | select(.value[1] == "1")] | length' <<<"$ROLE_JSON")

if [[ "$metric_count" != '2' || "$primary_count" != '1' || "$replica_count" != '1' ]]; then
  echo "ERROR: MariaDB 역할 메트릭이 예상과 다릅니다: total=${metric_count}, primary=${primary_count}, replica=${replica_count}" >&2
  echo 'ERROR: 대시보드는 변경하지 않았습니다.' >&2
  exit 4
fi

echo 'MARIADB_ROLE_METRICS_OK primary=1 replica=1'

echo '[2/4] 기존 대시보드를 백업하고 역할 패널을 추가합니다.'
cp -a -- "$DASHBOARD" "$BACKUP"

jq '
  .panels |= map(select(.id != 17)) |
  ([.panels[] | ((.gridPos.y // 0) + (.gridPos.h // 0))] | max // 0) as $next_y |
  .panels += [
    {
      "id": 17,
      "type": "stat",
      "title": "MariaDB 역할 (자동 판별)",
      "description": "read_only=0은 PRIMARY, read_only=1은 REPLICA입니다. Primary가 하나가 아니거나 없으면 DB failover 상태를 확인하세요.",
      "datasource": {"type": "prometheus", "uid": "${DS_PROMETHEUS}"},
      "gridPos": {"h": 6, "w": 24, "x": 0, "y": $next_y},
      "targets": [
        {
          "refId": "A",
          "editorMode": "code",
          "expr": "mysql_global_variables_read_only{job=\"mariadb\"}",
          "legendFormat": "{{instance}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": {"text": "PRIMARY", "color": "green"},
                "1": {"text": "REPLICA", "color": "blue"}
              }
            }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green", "value": null},
              {"color": "blue", "value": 1}
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "reduceOptions": {"values": false, "calcs": ["lastNotNull"], "fields": ""},
        "orientation": "auto",
        "textMode": "value_and_name",
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "auto",
        "wideLayout": true
      }
    }
  ] |
  .version = ((.version // 0) + 1)
' "$DASHBOARD" > "$TEMP_FILE"

jq empty "$TEMP_FILE"
install -o 472 -g 472 -m 0640 "$TEMP_FILE" "$DASHBOARD"
restorecon -F "$DASHBOARD" 2>/dev/null || true

echo '[3/4] Grafana를 재시작하고 대시보드를 반영합니다.'
if ! systemctl restart grafana.service; then
  cp -a -- "$BACKUP" "$DASHBOARD"
  systemctl restart grafana.service || true
  echo 'ERROR: Grafana 재시작 실패. 기존 대시보드로 복구했습니다.' >&2
  exit 5
fi

for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "$GRAFANA_HEALTH_URL" >/dev/null; then
    break
  fi
  sleep 1
done

if ! curl -fsS --max-time 3 "$GRAFANA_HEALTH_URL" >/dev/null; then
  cp -a -- "$BACKUP" "$DASHBOARD"
  systemctl restart grafana.service || true
  echo 'ERROR: Grafana health 확인 실패. 기존 대시보드로 복구했습니다.' >&2
  exit 6
fi

echo '[4/4] 패널과 현재 역할을 확인합니다.'
jq -r '
  .panels[]
  | select(.id == 17)
  | [.id, .title, .targets[0].expr]
  | @tsv
' "$DASHBOARD"

echo '현재 수집값:'
jq -r '
  .data.result[]
  | [.metric.instance, .value[1]]
  | @tsv
' <<<"$ROLE_JSON"

echo 'MARIADB_ROLE_DASHBOARD_READY'
echo "DASHBOARD_BACKUP=${BACKUP}"
