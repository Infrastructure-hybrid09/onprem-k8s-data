#!/usr/bin/env bash
set -Eeuo pipefail

MAIN_DASHBOARD='/var/lib/grafana/dashboards/main-kubernetes.json'
OBS_DASHBOARD='/var/lib/grafana/dashboards/observability-platform.json'
STAMP=$(date +%Y%m%d-%H%M%S)
MAIN_BACKUP="${MAIN_DASHBOARD}.before-longhorn-removal-${STAMP}"
OBS_BACKUP="${OBS_DASHBOARD}.before-pc6-resource-panels-${STAMP}"
MAIN_TEMP=$(mktemp /tmp/main-kubernetes.XXXXXX.json)
OBS_TEMP=$(mktemp /tmp/observability-platform.XXXXXX.json)

cleanup() {
  rm -f -- "$MAIN_TEMP" "$OBS_TEMP"
}
trap cleanup EXIT

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

command -v jq >/dev/null

for file in "$MAIN_DASHBOARD" "$OBS_DASHBOARD"; do
  [[ -s "$file" ]] || {
    echo "ERROR: 대시보드 파일이 없습니다: $file" >&2
    exit 10
  }
done

cp -a -- "$MAIN_DASHBOARD" "$MAIN_BACKUP"
cp -a -- "$OBS_DASHBOARD" "$OBS_BACKUP"

jq '
  (.panels[] | select(.id == 5) | .targets[0].expr) = "up{job=\"main-kube-state-metrics\"}" |
  (.panels[] | select(.id == 5) | .title) = "Main kube-state-metrics" |
  (.panels[] | select(.id == 5) | .fieldConfig.defaults.mappings) = [
    {"options":{"0":{"color":"red","text":"DOWN"},"1":{"color":"green","text":"UP"}},"type":"value"}
  ] |
  .version = ((.version // 0) + 1)
' "$MAIN_DASHBOARD" > "$MAIN_TEMP"

jq '
  .panels |= map(if .id == 10 then .gridPos.y = 23 else . end) |
  .panels |= map(select(.id != 11 and .id != 12 and .id != 13)) |
  .panels += [
    {
      "datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},
      "fieldConfig":{"defaults":{"decimals":1,"max":100,"min":0,"unit":"percent"},"overrides":[]},
      "gridPos":{"h":9,"w":8,"x":0,"y":14},"id":11,
      "options":{"legend":{"displayMode":"table","placement":"bottom","showLegend":true},"tooltip":{"mode":"multi"}},
      "targets":[{"editorMode":"code","expr":"100 - (avg(rate(node_cpu_seconds_total{job=\"monitoring-node\",mode=\"idle\"}[5m])) * 100)","legendFormat":"PC6 Monitoring CPU","refId":"A"}],
      "title":"PC6 Monitoring VM CPU","type":"timeseries"
    },
    {
      "datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},
      "fieldConfig":{"defaults":{"decimals":1,"max":100,"min":0,"unit":"percent"},"overrides":[]},
      "gridPos":{"h":9,"w":8,"x":8,"y":14},"id":12,
      "options":{"legend":{"displayMode":"table","placement":"bottom","showLegend":true},"tooltip":{"mode":"multi"}},
      "targets":[{"editorMode":"code","expr":"100 * (1 - node_memory_MemAvailable_bytes{job=\"monitoring-node\"} / node_memory_MemTotal_bytes{job=\"monitoring-node\"})","legendFormat":"PC6 Monitoring RAM","refId":"A"}],
      "title":"PC6 Monitoring VM RAM","type":"timeseries"
    },
    {
      "datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},
      "fieldConfig":{"defaults":{"decimals":1,"max":100,"min":0,"unit":"percent"},"overrides":[]},
      "gridPos":{"h":9,"w":8,"x":16,"y":14},"id":13,
      "options":{"legend":{"displayMode":"table","placement":"bottom","showLegend":true},"tooltip":{"mode":"multi"}},
      "targets":[{"editorMode":"code","expr":"100 * (1 - node_filesystem_avail_bytes{job=\"monitoring-node\",mountpoint=\"/var/lib/prometheus\",fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{job=\"monitoring-node\",mountpoint=\"/var/lib/prometheus\",fstype!~\"tmpfs|overlay\"})","legendFormat":"Prometheus 데이터 디스크","refId":"A"}],
      "title":"PC6 Prometheus 데이터 디스크","type":"timeseries"
    }
  ] |
  .version = ((.version // 0) + 1)
' "$OBS_DASHBOARD" > "$OBS_TEMP"

jq empty "$MAIN_TEMP"
jq empty "$OBS_TEMP"

install -o 472 -g 472 -m 0640 "$MAIN_TEMP" "$MAIN_DASHBOARD"
install -o 472 -g 472 -m 0640 "$OBS_TEMP" "$OBS_DASHBOARD"
restorecon -F "$MAIN_DASHBOARD" "$OBS_DASHBOARD" 2>/dev/null || true

systemctl restart grafana.service

for _ in $(seq 1 30); do
  if curl -fsS http://192.168.14.73:3000/api/health >/dev/null 2>&1; then
    echo "DASHBOARD_FINALIZE_OK"
    echo "MAIN_DASHBOARD_BACKUP=$MAIN_BACKUP"
    echo "OBS_DASHBOARD_BACKUP=$OBS_BACKUP"
    exit 0
  fi
  sleep 1
done

cp -a -- "$MAIN_BACKUP" "$MAIN_DASHBOARD"
cp -a -- "$OBS_BACKUP" "$OBS_DASHBOARD"
systemctl restart grafana.service || true
echo 'ERROR: Grafana health 확인 실패. 두 대시보드를 이전 상태로 복구했습니다.' >&2
exit 20
