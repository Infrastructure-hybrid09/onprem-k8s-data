#!/usr/bin/env bash
set -Eeuo pipefail

DASHBOARD_DIR='/var/lib/grafana/dashboards'
GRAFANA_HEALTH_URL='http://192.168.14.73:3000/api/health'
STAMP=$(date +%Y%m%d-%H%M%S)

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

for command_name in jq curl systemctl grep; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 2
  }
done

[[ -d "$DASHBOARD_DIR" ]] || {
  echo "ERROR: 대시보드 디렉터리가 없습니다: $DASHBOARD_DIR" >&2
  exit 3
}

mapfile -t DASHBOARDS < <(
  grep -RIl \
    --include='*.json' \
    '"type"[[:space:]]*:[[:space:]]*"timeseries"' \
    "$DASHBOARD_DIR"
)

if [[ ${#DASHBOARDS[@]} -eq 0 ]]; then
  echo 'ERROR: Time series 패널이 있는 대시보드를 찾지 못했습니다.' >&2
  exit 4
fi

echo '[1/4] Time series 패널이 있는 대시보드를 백업합니다.'
BACKUPS=()
for dashboard in "${DASHBOARDS[@]}"; do
  backup="${dashboard}.before-area-style-${STAMP}"
  cp -a -- "$dashboard" "$backup"
  BACKUPS+=("$backup")
  echo "BACKUP=$backup"
done

rollback() {
  for index in "${!DASHBOARDS[@]}"; do
    cp -a -- "${BACKUPS[$index]}" "${DASHBOARDS[$index]}"
  done
  systemctl restart grafana.service || true
}

echo '[2/4] 모든 Time series를 영역 채움 그래프로 변경합니다.'
TOTAL_PANELS=0
for dashboard in "${DASHBOARDS[@]}"; do
  temp_file=$(mktemp /tmp/grafana-area-style.XXXXXX.json)
  panel_count=$(jq '[.. | objects | select(.type? == "timeseries")] | length' "$dashboard")

  if ! jq '
    walk(
      if type == "object" and .type? == "timeseries" then
        .fieldConfig = (.fieldConfig // {}) |
        .fieldConfig.defaults = (.fieldConfig.defaults // {}) |
        .fieldConfig.defaults.custom = (
          (.fieldConfig.defaults.custom // {}) + {
            "drawStyle": "line",
            "lineWidth": 2,
            "fillOpacity": 20,
            "gradientMode": "opacity",
            "stacking": {"mode": "none", "group": "A"}
          }
        )
      else . end
    ) |
    .version = ((.version // 0) + 1)
  ' "$dashboard" > "$temp_file"; then
    rm -f -- "$temp_file"
    rollback
    echo "ERROR: 대시보드 변환 실패: $dashboard" >&2
    exit 5
  fi

  if ! jq empty "$temp_file"; then
    rm -f -- "$temp_file"
    rollback
    echo "ERROR: 변환된 JSON 검증 실패: $dashboard" >&2
    exit 6
  fi

  install -o 472 -g 472 -m 0640 "$temp_file" "$dashboard"
  restorecon -F "$dashboard" 2>/dev/null || true
  rm -f -- "$temp_file"
  TOTAL_PANELS=$((TOTAL_PANELS + panel_count))
  echo "UPDATED=$dashboard PANELS=$panel_count"
done

echo '[3/4] Grafana를 재시작하고 Ready 상태를 확인합니다.'
systemctl restart grafana.service

for _ in $(seq 1 30); do
  if curl -fsS "$GRAFANA_HEALTH_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "$GRAFANA_HEALTH_URL" >/dev/null; then
  rollback
  echo 'ERROR: Grafana Ready 확인 실패. 기존 대시보드로 복구했습니다.' >&2
  exit 7
fi

echo '[4/4] 적용 결과를 확인합니다.'
echo "AREA_STYLE_DASHBOARDS=${#DASHBOARDS[@]}"
echo "AREA_STYLE_PANELS=$TOTAL_PANELS"
echo 'GRAFANA_AREA_STYLE_READY'
