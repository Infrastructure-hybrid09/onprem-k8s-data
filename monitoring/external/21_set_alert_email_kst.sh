#!/usr/bin/env bash
set -Eeuo pipefail

ALERTMANAGER_IMAGE='quay.io/prometheus/alertmanager:v0.33.1'
ALERT_CONFIG='/etc/alertmanager/alertmanager.yml'
TEMPLATE_FILE='/etc/alertmanager/templates/infraready-email.tmpl'
STAMP=$(date +%Y%m%d-%H%M%S)
CONFIG_BACKUP="${ALERT_CONFIG}.before-kst-${STAMP}"
TEMPLATE_BACKUP="${TEMPLATE_FILE}.before-kst-${STAMP}"

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

for command_name in python3 podman curl grep; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 2
  }
done

for required_file in "$ALERT_CONFIG" "$TEMPLATE_FILE"; do
  [[ -s "$required_file" ]] || {
    echo "ERROR: 필수 파일이 없거나 비어 있습니다: $required_file" >&2
    exit 3
  }
done

echo '[1/5] Alertmanager 설정과 이메일 템플릿을 백업합니다.'
cp -a -- "$ALERT_CONFIG" "$CONFIG_BACKUP"
cp -a -- "$TEMPLATE_FILE" "$TEMPLATE_BACKUP"

echo '[2/5] 발생·복구 시각을 Asia/Seoul 기준으로 변경합니다.'
python3 - "$ALERT_CONFIG" "$TEMPLATE_FILE" <<'PY'
from pathlib import Path
import sys

paths = [Path(value) for value in sys.argv[1:]]

replacements = {
    '{{ .StartsAt }}': '{{ date "2006-01-02 15:04:05 MST" (tz "Asia/Seoul" .StartsAt) }}',
    '{{ .EndsAt }}': '{{ date "2006-01-02 15:04:05 MST" (tz "Asia/Seoul" .EndsAt) }}',
}

for path in paths:
    text = path.read_text(encoding="utf-8")
    for old, new in replacements.items():
        text = text.replace(old, new)
    path.write_text(text, encoding="utf-8")
PY

echo '[3/5] Alertmanager 설정과 템플릿 구문을 검증합니다.'
if ! podman run \
  --rm \
  --security-opt label=disable \
  --entrypoint=/bin/amtool \
  -v /etc/alertmanager:/etc/alertmanager:ro \
  "$ALERTMANAGER_IMAGE" \
  check-config \
  /etc/alertmanager/alertmanager.yml; then
  cp -a -- "$CONFIG_BACKUP" "$ALERT_CONFIG"
  cp -a -- "$TEMPLATE_BACKUP" "$TEMPLATE_FILE"
  echo 'ERROR: 설정 검증 실패. 기존 파일로 복구했습니다.' >&2
  exit 4
fi

echo '[4/5] 실행 중인 시험 경보를 유지한 채 설정만 다시 읽습니다.'
if ! podman kill --signal HUP alertmanager >/dev/null; then
  cp -a -- "$CONFIG_BACKUP" "$ALERT_CONFIG"
  cp -a -- "$TEMPLATE_BACKUP" "$TEMPLATE_FILE"
  echo 'ERROR: Alertmanager 설정 Reload에 실패했습니다.' >&2
  exit 5
fi

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9093/-/ready >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS http://127.0.0.1:9093/-/ready >/dev/null; then
  cp -a -- "$CONFIG_BACKUP" "$ALERT_CONFIG"
  cp -a -- "$TEMPLATE_BACKUP" "$TEMPLATE_FILE"
  podman kill --signal HUP alertmanager >/dev/null 2>&1 || true
  echo 'ERROR: Alertmanager Ready 확인에 실패하여 기존 파일로 복구했습니다.' >&2
  exit 6
fi

echo '[5/5] KST 템플릿 반영 결과를 확인합니다.'
grep -q 'tz "Asia/Seoul" .StartsAt' "$TEMPLATE_FILE"
grep -q 'tz "Asia/Seoul" .EndsAt' "$TEMPLATE_FILE"

echo 'ALERT_EMAIL_KST_READY'
echo "CONFIG_BACKUP=$CONFIG_BACKUP"
echo "TEMPLATE_BACKUP=$TEMPLATE_BACKUP"
echo '기존 10분 시험 경보는 유지되며, 만료 시 새 KST 형식으로 복구 메일이 발송됩니다.'
