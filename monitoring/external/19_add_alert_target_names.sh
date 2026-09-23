#!/usr/bin/env bash
set -Eeuo pipefail

ALERTMANAGER_IMAGE='quay.io/prometheus/alertmanager:v0.33.1'
ALERT_CONFIG='/etc/alertmanager/alertmanager.yml'
TEMPLATE_FILE='/etc/alertmanager/templates/infraready-email.tmpl'
STAMP=$(date +%Y%m%d-%H%M%S)
CONFIG_BACKUP="${ALERT_CONFIG}.before-target-names-${STAMP}"
TEMPLATE_BACKUP="${TEMPLATE_FILE}.before-target-names-${STAMP}"
TEST_JSON=$(mktemp /tmp/alertmanager-target-name-test.XXXXXX.json)

cleanup() {
  rm -f -- "$TEST_JSON"
}
trap cleanup EXIT

rollback() {
  cp -a -- "$CONFIG_BACKUP" "$ALERT_CONFIG"
  cp -a -- "$TEMPLATE_BACKUP" "$TEMPLATE_FILE"
  systemctl restart alertmanager.service || true
}

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

for command_name in python3 podman curl jq systemctl; do
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

echo '[1/6] Alertmanager 설정과 이메일 템플릿을 백업합니다.'
cp -a -- "$ALERT_CONFIG" "$CONFIG_BACKUP"
cp -a -- "$TEMPLATE_FILE" "$TEMPLATE_BACKUP"

echo '[2/6] IP 주소에 대응하는 영문 VM 이름을 템플릿에 추가합니다.'
python3 - "$TEMPLATE_FILE" "$ALERT_CONFIG" <<'PY'
from pathlib import Path
import re
import sys

template_path = Path(sys.argv[1])
config_path = Path(sys.argv[2])
text = template_path.read_text(encoding="utf-8")

begin = '{{/* BEGIN INFRAREADY TARGET NAME */}}'
end = '{{/* END INFRAREADY TARGET NAME */}}'

mapping = r'''{{/* BEGIN INFRAREADY TARGET NAME */}}
{{ define "infraready.target.name" -}}
{{- if eq .Labels.node "cp1" -}}control1
{{- else if eq .Labels.node "cp2" -}}control2
{{- else if eq .Labels.node "cp3" -}}control3
{{- else if eq .Labels.node "worker1" -}}worker1
{{- else if eq .Labels.node "worker2" -}}worker2
{{- else if eq .Labels.node "worker3" -}}worker3
{{- else if eq .Labels.instance "192.168.14.11:9100" -}}lb1
{{- else if eq .Labels.instance "192.168.14.12:9100" -}}lb2
{{- else if eq .Labels.instance "192.168.14.21:9100" -}}devops
{{- else if eq .Labels.instance "192.168.14.51:9100" -}}db-primary
{{- else if eq .Labels.instance "192.168.14.52:9100" -}}db-replica
{{- else if eq .Labels.instance "192.168.14.61:9100" -}}nfs
{{- else if eq .Labels.instance "192.168.14.62:9100" -}}infra
{{- else if eq .Labels.instance "192.168.14.72:9100" -}}minio
{{- else if eq .Labels.instance "192.168.34.31:9100" -}}control1
{{- else if eq .Labels.instance "192.168.34.32:9100" -}}control2
{{- else if eq .Labels.instance "192.168.34.33:9100" -}}control3
{{- else if eq .Labels.instance "192.168.34.41:9100" -}}worker1
{{- else if eq .Labels.instance "192.168.34.42:9100" -}}worker2
{{- else if eq .Labels.instance "192.168.34.43:9100" -}}worker3
{{- else if eq .Labels.instance "192.168.34.71:9100" -}}dr-k3s
{{- else if eq .Labels.instance "192.168.44.51:9104" -}}db-primary
{{- else if eq .Labels.instance "192.168.44.52:9104" -}}db-replica
{{- else if eq .Labels.instance "192.168.34.100:6443" -}}main-api-vip
{{- else if eq .Labels.instance "192.168.34.71:6443" -}}dr-k3s
{{- else if eq .Labels.instance "192.168.14.73:3000" -}}monitoring
{{- else if eq .Labels.instance "127.0.0.1:9090" -}}monitoring
{{- else if eq .Labels.instance "127.0.0.1:9093" -}}monitoring
{{- else if eq .Labels.instance "monitoring" -}}monitoring
{{- else if eq .Labels.instance "monitoring-pc6" -}}monitoring
{{- else if .Labels.node -}}{{ .Labels.node }}
{{- else -}}{{ .Labels.job }}
{{- end -}}
{{- end }}
{{/* END INFRAREADY TARGET NAME */}}'''

if begin in text and end in text:
    text = re.sub(
        re.escape(begin) + r'.*?' + re.escape(end),
        mapping,
        text,
        flags=re.S,
    )
else:
    anchor = '{{ define "infraready.email.html" }}'
    if anchor not in text:
        raise SystemExit(f"ERROR: HTML template anchor not found: {anchor}")
    text = text.replace(anchor, mapping + "\n\n" + anchor, 1)

old_html = '<div><strong>대상 주소:</strong> {{ .Labels.instance }}</div>'
new_html = '<div><strong>대상 주소:</strong> {{ .Labels.instance }} ({{ template "infraready.target.name" . }})</div>'
if new_html in text:
    pass
elif old_html in text:
    text = text.replace(old_html, new_html)
else:
    raise SystemExit("ERROR: HTML target address line not found")

template_path.write_text(text, encoding="utf-8")

config = config_path.read_text(encoding="utf-8")
old_text = '          대상 주소: {{ .Labels.instance }}'
new_text = '          대상 주소: {{ .Labels.instance }} ({{ template "infraready.target.name" . }})'
if new_text in config:
    pass
elif old_text in config:
    config = config.replace(old_text, new_text)
# HTML 메일이 기본이며 text 본문이 없는 설정도 허용한다.
config_path.write_text(config, encoding="utf-8")
PY

chown root:root "$TEMPLATE_FILE"
chmod 0644 "$TEMPLATE_FILE"

echo '[3/6] Alertmanager 설정과 템플릿 구문을 검증합니다.'
if ! podman run \
  --rm \
  --entrypoint=/bin/amtool \
  -v /etc/alertmanager:/etc/alertmanager:ro,Z \
  "$ALERTMANAGER_IMAGE" \
  check-config \
  /etc/alertmanager/alertmanager.yml; then
  rollback
  echo 'ERROR: 설정 검증 실패. 기존 설정으로 복구했습니다.' >&2
  exit 4
fi

echo '[4/6] Alertmanager를 재시작하고 Ready 상태를 확인합니다.'
if ! systemctl restart alertmanager.service; then
  rollback
  echo 'ERROR: Alertmanager 재시작 실패. 기존 설정으로 복구했습니다.' >&2
  exit 5
fi

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9093/-/ready >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS http://127.0.0.1:9093/-/ready >/dev/null; then
  rollback
  echo 'ERROR: Alertmanager Ready 확인 실패. 기존 설정으로 복구했습니다.' >&2
  exit 6
fi

echo '[5/6] worker1 이름 표시를 확인할 시험 경보를 등록합니다.'
TEST_ID=$(date -u +%Y%m%dT%H%M%SZ)
STARTS_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENDS_AT=$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)

jq -n \
  --arg test_id "$TEST_ID" \
  --arg starts_at "$STARTS_AT" \
  --arg ends_at "$ENDS_AT" \
  '[{
    labels: {
      alertname: "GmailTargetNameTest",
      severity: "warning",
      instance: "192.168.34.41:9100",
      node: "worker1",
      job: "node-exporter-k8s-existing",
      test_id: $test_id
    },
    annotations: {
      summary: "Alertmanager VM 이름 표시 시험",
      description: "메일 대상 주소가 192.168.34.41:9100 (worker1) 형태로 표시되는지 확인합니다."
    },
    startsAt: $starts_at,
    endsAt: $ends_at
  }]' > "$TEST_JSON"

curl -fsS \
  -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "@$TEST_JSON" \
  http://127.0.0.1:9093/api/v2/alerts

echo '[6/6] 적용 결과를 확인합니다.'
grep -q 'infraready.target.name' "$TEMPLATE_FILE"
grep -q '192.168.34.41:9100' "$TEMPLATE_FILE"

echo 'ALERT_TARGET_NAMES_READY'
echo "TEST_ALERT_ID=$TEST_ID"
echo "CONFIG_BACKUP=$CONFIG_BACKUP"
echo "TEMPLATE_BACKUP=$TEMPLATE_BACKUP"
echo '약 30초 후 메일에서 대상 주소: 192.168.34.41:9100 (worker1)을 확인하세요.'
