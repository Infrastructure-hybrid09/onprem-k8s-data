#!/usr/bin/env bash
set -Eeuo pipefail

DASHBOARD_DIR='/var/lib/grafana/dashboards'
GRAFANA_HEALTH_URL='http://192.168.14.73:3000/api/health'
STAMP=$(date +%Y%m%d-%H%M%S)
TEMP_FILE=$(mktemp /tmp/data-platform-mariadb-disk.XXXXXX.json)

cleanup() {
  rm -f -- "$TEMP_FILE"
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

DASHBOARD=$(dashboard_for_uid 'infraready-data-platform') || {
  echo 'ERROR: Infrastructure - Data Platform 대시보드를 찾지 못했습니다.' >&2
  exit 3
}
BACKUP="${DASHBOARD}.before-mariadb-disk-${STAMP}"

disk_panel_count=$(jq -r '
  [.panels[]
   | select(
       .title == "Data Platform 루트 디스크"
       or .title == "MariaDB 데이터 디스크 사용량"
       or .title == "MariaDB VM 디스크 사용량"
     )]
  | length
' "$DASHBOARD")
[[ "$disk_panel_count" == '1' ]] || {
  echo "ERROR: 변경할 디스크 패널이 정확히 1개가 아닙니다: count=${disk_panel_count}" >&2
  exit 4
}

vm_panel_count=$(jq -r '
  [.panels[]
   | select(.title == "MariaDB 연결 상태" or .title == "MariaDB VM 상태")]
  | length
' "$DASHBOARD")
[[ "$vm_panel_count" == '1' ]] || {
  echo "ERROR: 변경할 MariaDB 상태 패널이 정확히 1개가 아닙니다: count=${vm_panel_count}" >&2
  exit 5
}

role_panel_count=$(jq -r '
  [.panels[]
   | select(.title == "MariaDB 역할 (자동 판별)" or .title == "MariaDB 역할")]
  | length
' "$DASHBOARD")
[[ "$role_panel_count" == '1' ]] || {
  echo "ERROR: 변경할 MariaDB 역할 패널이 정확히 1개가 아닙니다: count=${role_panel_count}" >&2
  exit 6
}

cp -a -- "$DASHBOARD" "$BACKUP"

jq '
  .panels |= map(
    if (.title == "Data Platform 루트 디스크" or .title == "MariaDB 데이터 디스크 사용량" or .title == "MariaDB VM 디스크 사용량") then
      .title = "MariaDB VM 디스크 사용량" |
      .description = "db-primary와 db-replica VM의 루트 파일시스템 사용률입니다. /var/lib/mysql이 별도 마운트가 아니라면 MariaDB 데이터 사용량도 이 값에 포함됩니다." |
      .targets = [
        {
          "refId": "A",
          "editorMode": "code",
          "expr": "100 * (1 - node_filesystem_avail_bytes{job=\"node-exporter-vm\",instance=~\"192.168.14.(51|52):9100\",mountpoint=\"/\",fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{job=\"node-exporter-vm\",instance=~\"192.168.14.(51|52):9100\",mountpoint=\"/\",fstype!~\"tmpfs|overlay\"})",
          "legendFormat": "{{instance}}",
          "range": true
        }
      ]
    elif (.title == "MariaDB 연결 상태" or .title == "MariaDB VM 상태") then
      .title = "MariaDB VM 상태" |
      .description = "DB VM의 Node Exporter 수집 상태를 기준으로 VM 생존 여부를 표시합니다." |
      .gridPos = {"h":5,"w":6,"x":0,"y":0} |
      .targets = [
        {
          "refId": "A",
          "editorMode": "code",
          "expr": "up{job=\"node-exporter-vm\",instance=\"192.168.14.51:9100\"}",
          "instant": true,
          "range": false,
          "legendFormat": "192.168.14.51:9100\ndb-primary"
        },
        {
          "refId": "B",
          "editorMode": "code",
          "expr": "up{job=\"node-exporter-vm\",instance=\"192.168.14.52:9100\"}",
          "instant": true,
          "range": false,
          "legendFormat": "192.168.14.52:9100\ndb-replica"
        }
      ] |
      .options.orientation = "horizontal" |
      .options.textMode = "value_and_name" |
      .options.wideLayout = false
    elif (.title == "MariaDB 역할 (자동 판별)" or .title == "MariaDB 역할") then
      .title = "MariaDB 역할" |
      .description = "read_only=0은 PRIMARY, read_only=1은 REPLICA로 표시합니다." |
      .gridPos = {"h":5,"w":6,"x":18,"y":0} |
      .targets = [
        {
          "refId": "A",
          "editorMode": "code",
          "expr": "mysql_global_variables_read_only{job=\"mariadb\",instance=\"192.168.44.51:9104\"}",
          "instant": true,
          "range": false,
          "legendFormat": "192.168.44.51:9104\ndb-primary"
        },
        {
          "refId": "B",
          "editorMode": "code",
          "expr": "mysql_global_variables_read_only{job=\"mariadb\",instance=\"192.168.44.52:9104\"}",
          "instant": true,
          "range": false,
          "legendFormat": "192.168.44.52:9104\ndb-replica"
        }
      ] |
      .options.orientation = "horizontal" |
      .options.textMode = "value_and_name" |
      .options.wideLayout = false
    elif (.title == "MaxScale VM 상태" or .title == "MaxScale") then
      .title = "MaxScale" |
      .gridPos = {"h":5,"w":4,"x":6,"y":0}
    elif (.title == "NFS VM 상태" or .title == "NFS") then
      .title = "NFS" |
      .gridPos = {"h":5,"w":4,"x":10,"y":0}
    elif (.title == "MinIO VM 상태" or .title == "MinIO") then
      .title = "MinIO" |
      .gridPos = {"h":5,"w":4,"x":14,"y":0}
    else .
    end
  ) |
  .version = ((.version // 0) + 1)
' "$DASHBOARD" > "$TEMP_FILE"

jq empty "$TEMP_FILE"
install -o 472 -g 472 -m 0640 "$TEMP_FILE" "$DASHBOARD"
restorecon -F "$DASHBOARD" 2>/dev/null || true

if ! systemctl restart grafana.service; then
  cp -a -- "$BACKUP" "$DASHBOARD"
  systemctl restart grafana.service || true
  echo 'ERROR: Grafana 재시작 실패. 기존 대시보드로 복구했습니다.' >&2
  exit 7
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
  exit 8
fi

jq -r '
  .panels[]
  | select(.title == "MariaDB VM 상태" or .title == "MariaDB 역할" or .title == "MariaDB VM 디스크 사용량")
  | [.title, (.targets | map(.legendFormat // .expr) | join(" / "))]
  | @tsv
' "$DASHBOARD"

echo 'MARIADB_DATA_PLATFORM_PANELS_UPDATE_OK'
echo "DASHBOARD=${DASHBOARD}"
echo "BACKUP=${BACKUP}"
