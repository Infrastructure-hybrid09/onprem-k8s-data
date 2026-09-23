#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/infraready-log-investigation.json"
DEST='/var/lib/grafana/dashboards/infraready-log-investigation.json'
BACKUP="${DEST}.before-log-dashboard-$(date +%Y%m%d-%H%M%S)"

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

command -v jq >/dev/null || {
  echo 'ERROR: jq가 필요합니다.' >&2
  exit 2
}
[[ -s "$SOURCE" ]] || {
  echo "ERROR: 대시보드 원본이 없습니다: $SOURCE" >&2
  exit 3
}

jq empty "$SOURCE"

if [[ -e "$DEST" ]]; then
  cp -a -- "$DEST" "$BACKUP"
fi

install -o 472 -g 472 -m 0640 "$SOURCE" "$DEST"

# Grafana는 :Z bind mount로 실행되므로, 실행 중인 컨테이너에 새 파일을
# 추가할 때 기존 대시보드와 동일한 SELinux 컨텍스트를 명시적으로 맞춘다.
if command -v chcon >/dev/null; then
  REFERENCE=$(find /var/lib/grafana/dashboards -maxdepth 1 -type f -name '*.json' ! -path "$DEST" -print -quit || true)
  if [[ -n "$REFERENCE" ]]; then
    chcon --reference="$REFERENCE" "$DEST" || true
  fi
fi

echo 'LOG_DASHBOARD_INSTALL_OK'
echo "DASHBOARD=$DEST"
[[ -e "$BACKUP" ]] && echo "DASHBOARD_BACKUP=$BACKUP"
echo 'Grafana 파일 프로바이더가 30초 이내에 대시보드를 반영합니다.'

GRAFANA_HEALTH_URL="${GRAFANA_HEALTH_URL:-http://192.168.14.73:3000/api/health}"

if curl -fsS --max-time 5 "$GRAFANA_HEALTH_URL" >/dev/null; then
  echo 'GRAFANA_HEALTHY'
else
  echo "WARNING: Grafana API health 확인 실패: $GRAFANA_HEALTH_URL" >&2
fi
