#!/usr/bin/env bash
set -Eeuo pipefail

DASHBOARD_DIR='/var/lib/grafana/dashboards'
PROMETHEUS_URL='http://127.0.0.1:9090'
GRAFANA_HEALTH_URL='http://192.168.14.73:3000/api/health'
STAMP=$(date +%Y%m%d-%H%M%S)
OBS_TEMP=$(mktemp /tmp/observability-remove-mariadb-role.XXXXXX.json)
DATA_TEMP=$(mktemp /tmp/data-platform-add-mariadb-role.XXXXXX.json)

cleanup() {
  rm -f -- "$OBS_TEMP" "$DATA_TEMP"
}
trap cleanup EXIT

dashboard_for_uid() {
  local uid=$1 candidate
  for candidate in "$DASHBOARD_DIR"/*.json; do
    [[ -f "$candidate" ]] || continue
    if jq -e --arg uid "$uid" '.uid == $uid' "$candidate" >/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

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

OBS_DASHBOARD=$(dashboard_for_uid 'infraready-observability') || {
  echo 'ERROR: Infrastructure - Observability Platform 파일을 찾지 못했습니다.' >&2
  exit 3
}
DATA_DASHBOARD=$(dashboard_for_uid 'infraready-data-platform') || {
  echo 'ERROR: Infrastructure - Data Platform 파일을 찾지 못했습니다.' >&2
  exit 4
}

OBS_BACKUP="${OBS_DASHBOARD}.before-mariadb-role-move-${STAMP}"
DATA_BACKUP="${DATA_DASHBOARD}.before-mariadb-role-move-${STAMP}"

status_panel_count=$(jq -r '
  [.panels[]
   | select(
       .title == "MariaDB 연결 상태"
       or .title == "MaxScale VM 상태"
       or .title == "NFS VM 상태"
       or .title == "MinIO VM 상태"
     )]
  | length
' "$DATA_DASHBOARD")
[[ "$status_panel_count" == '4' ]] || {
  echo "ERROR: Data Platform 상단 상태 패널 4개를 찾지 못했습니다: count=${status_panel_count}" >&2
  echo 'ERROR: 대시보드는 변경하지 않았습니다.' >&2
  exit 5
}

echo '[1/5] MariaDB Primary/Replica 역할 메트릭을 확인합니다.'
ROLE_JSON=$(curl -fsSG "${PROMETHEUS_URL}/api/v1/query" \
  --data-urlencode 'query=mysql_global_variables_read_only{job="mariadb"}')
metric_count=$(jq -r '.data.result | length' <<<"$ROLE_JSON")
primary_count=$(jq -r '[.data.result[] | select(.value[1] == "0")] | length' <<<"$ROLE_JSON")
replica_count=$(jq -r '[.data.result[] | select(.value[1] == "1")] | length' <<<"$ROLE_JSON")

if [[ "$metric_count" != '2' || "$primary_count" != '1' || "$replica_count" != '1' ]]; then
  echo "ERROR: MariaDB 역할 메트릭이 예상과 다릅니다: total=${metric_count}, primary=${primary_count}, replica=${replica_count}" >&2
  echo 'ERROR: 대시보드는 변경하지 않았습니다.' >&2
  exit 6
fi

echo 'MARIADB_ROLE_METRICS_OK primary=1 replica=1'

echo '[2/5] Observability 대시보드에서 잘못 배치된 역할 패널을 제거합니다.'
cp -a -- "$OBS_DASHBOARD" "$OBS_BACKUP"
jq '
  .panels |= map(select(.title != "MariaDB 역할 (자동 판별)")) |
  .version = ((.version // 0) + 1)
' "$OBS_DASHBOARD" > "$OBS_TEMP"
jq empty "$OBS_TEMP"

echo '[3/5] Data Platform 상단 상태 패널을 조정하고 MariaDB 역할 패널을 추가합니다.'
cp -a -- "$DATA_DASHBOARD" "$DATA_BACKUP"
jq '
  .panels |= map(select(.title != "MariaDB 역할 (자동 판별)")) |
  ([.panels[] | .id] | max + 1) as $role_id |
  .panels |= map(
    if .title == "MariaDB 연결 상태" then .gridPos = {"h":5,"w":4,"x":0,"y":0}
    elif .title == "MaxScale VM 상태" then .gridPos = {"h":5,"w":4,"x":4,"y":0}
    elif .title == "NFS VM 상태" then .gridPos = {"h":5,"w":4,"x":8,"y":0}
    elif .title == "MinIO VM 상태" then .gridPos = {"h":5,"w":4,"x":12,"y":0}
    else .
    end
  ) |
  .panels += [
    {
      "id": $role_id,
      "type": "stat",
      "title": "MariaDB 역할 (자동 판별)",
      "description": "read_only=0은 PRIMARY, read_only=1은 REPLICA입니다. Primary가 하나가 아니거나 없으면 DB failover 상태를 확인하세요.",
      "datasource": {"type": "prometheus", "uid": "${DS_PROMETHEUS}"},
      "gridPos": {"h":5,"w":8,"x":16,"y":0},
      "targets": [
        {
          "refId": "A",
          "editorMode": "code",
          "expr": "mysql_global_variables_read_only{job=\"mariadb\"}",
          "instant": true,
          "range": false,
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
' "$DATA_DASHBOARD" > "$DATA_TEMP"
jq empty "$DATA_TEMP"

install -o 472 -g 472 -m 0640 "$OBS_TEMP" "$OBS_DASHBOARD"
install -o 472 -g 472 -m 0640 "$DATA_TEMP" "$DATA_DASHBOARD"
restorecon -F "$OBS_DASHBOARD" "$DATA_DASHBOARD" 2>/dev/null || true

echo '[4/5] Grafana를 재시작하고 반영 상태를 확인합니다.'
if ! systemctl restart grafana.service; then
  cp -a -- "$OBS_BACKUP" "$OBS_DASHBOARD"
  cp -a -- "$DATA_BACKUP" "$DATA_DASHBOARD"
  systemctl restart grafana.service || true
  echo 'ERROR: Grafana 재시작 실패. 두 대시보드를 복구했습니다.' >&2
  exit 7
fi

for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "$GRAFANA_HEALTH_URL" >/dev/null; then
    break
  fi
  sleep 1
done

if ! curl -fsS --max-time 3 "$GRAFANA_HEALTH_URL" >/dev/null; then
  cp -a -- "$OBS_BACKUP" "$OBS_DASHBOARD"
  cp -a -- "$DATA_BACKUP" "$DATA_DASHBOARD"
  systemctl restart grafana.service || true
  echo 'ERROR: Grafana health 확인 실패. 두 대시보드를 복구했습니다.' >&2
  exit 8
fi

echo '[5/5] Data Platform 역할 패널을 확인합니다.'
jq -r '
  .panels[]
  | select(.title == "MariaDB 연결 상태" or .title == "MaxScale VM 상태" or .title == "NFS VM 상태" or .title == "MinIO VM 상태" or .title == "MariaDB 역할 (자동 판별)")
  | [.title, .gridPos.x, .gridPos.y, .gridPos.w, .gridPos.h]
  | @tsv
' "$DATA_DASHBOARD"

echo '현재 수집값:'
jq -r '.data.result[] | [.metric.instance, .value[1]] | @tsv' <<<"$ROLE_JSON"
echo 'MARIADB_ROLE_MOVED_TO_DATA_PLATFORM_READY'
echo "OBSERVABILITY_BACKUP=${OBS_BACKUP}"
echo "DATA_PLATFORM_BACKUP=${DATA_BACKUP}"
