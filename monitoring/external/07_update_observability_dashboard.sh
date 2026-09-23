#!/usr/bin/env bash
set -Eeuo pipefail

DASHBOARD='/var/lib/grafana/dashboards/observability-platform.json'
BACKUP="${DASHBOARD}.before-pc6-$(date +%Y%m%d-%H%M%S)"
TEMP_FILE=$(mktemp /tmp/observability-platform.XXXXXX.json)

cleanup() {
  rm -f -- "$TEMP_FILE"
}
trap cleanup EXIT

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

command -v jq >/dev/null
[[ -s "$DASHBOARD" ]] || {
  echo "ERROR: 대시보드 파일이 없습니다: $DASHBOARD" >&2
  exit 10
}

cp -a -- "$DASHBOARD" "$BACKUP"

jq '
  (.panels[] | select(.id == 1) | .targets[0].expr) = "up{job=\"prometheus\"}" |
  (.panels[] | select(.id == 1) | .title) = "Prometheus Ready (PC6)" |
  (.panels[] | select(.id == 2) | .targets[0].expr) = "up{job=\"grafana\"}" |
  (.panels[] | select(.id == 2) | .title) = "Grafana Ready (PC6)" |
  (.panels[] | select(.id == 3) | .targets[0].expr) = "up{job=\"alertmanager\"}" |
  (.panels[] | select(.id == 3) | .title) = "Alertmanager Ready (PC6)" |
  .version = ((.version // 0) + 1)
' "$DASHBOARD" > "$TEMP_FILE"

jq empty "$TEMP_FILE"
install -o 472 -g 472 -m 0640 "$TEMP_FILE" "$DASHBOARD"
restorecon -F "$DASHBOARD" 2>/dev/null || true
systemctl restart grafana.service

for _ in $(seq 1 30); do
  if curl -fsS http://192.168.14.73:3000/api/health >/dev/null; then
    echo "DASHBOARD_UPDATE_OK: $DASHBOARD"
    echo "DASHBOARD_BACKUP=$BACKUP"
    exit 0
  fi
  sleep 1
done

cp -a -- "$BACKUP" "$DASHBOARD"
systemctl restart grafana.service || true
echo 'ERROR: Grafana health 확인 실패. 기존 대시보드로 복구했습니다.' >&2
exit 20
