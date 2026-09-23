#!/usr/bin/env bash
set -Eeuo pipefail

ALERTMANAGER_IMAGE='quay.io/prometheus/alertmanager:v0.33.1'
ALERT_CONFIG='/etc/alertmanager/alertmanager.yml'
TEMPLATE_FILE='/etc/alertmanager/templates/infraready-email.tmpl'
STAMP=$(date +%Y%m%d-%H%M%S)
CONFIG_BACKUP="${ALERT_CONFIG}.before-alert-summary-${STAMP}"
TEMPLATE_BACKUP="${TEMPLATE_FILE}.before-alert-summary-${STAMP}"
TEST_JSON=$(mktemp /tmp/alertmanager-summary-test.XXXXXX.json)

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

for command_name in python3 podman curl jq systemctl grep; do
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

grep -q 'define "infraready.target.name"' "$TEMPLATE_FILE" || {
  echo 'ERROR: VM 이름 템플릿이 없습니다. 19_add_alert_target_names.sh를 먼저 적용하세요.' >&2
  exit 4
}

echo '[1/6] Alertmanager 설정과 이메일 템플릿을 백업합니다.'
cp -a -- "$ALERT_CONFIG" "$CONFIG_BACKUP"
cp -a -- "$TEMPLATE_FILE" "$TEMPLATE_BACKUP"

echo '[2/6] 모든 경보를 하나의 알림 그룹으로 묶습니다.'
python3 - "$ALERT_CONFIG" "$TEMPLATE_FILE" <<'PY'
from pathlib import Path
import re
import sys

config_path = Path(sys.argv[1])
template_path = Path(sys.argv[2])

config = config_path.read_text(encoding="utf-8")

if re.search(r"(?m)^  group_by: \[\]\s*$", config) is None:
    config, count = re.subn(
        r"(?m)^  group_by:\s*\n(?:    - [^\n]+\n)+",
        "  group_by: []\n",
        config,
        count=1,
    )
    if count != 1:
        raise SystemExit("ERROR: route.group_by block not found")

config = re.sub(
    r"(?m)^  group_interval:\s*[^\s]+\s*$",
    "  group_interval: 1m",
    config,
    count=1,
)

subject = "          Subject: '[InfraReady] {{ template \"infraready.status.ko\" . }} - 장애 상태 요약 (발생 {{ len .Alerts.Firing }} / 복구 {{ len .Alerts.Resolved }})'"
config, count = re.subn(
    r"(?m)^\s{10}Subject:.*$",
    subject,
    config,
    count=1,
)
if count != 1:
    raise SystemExit("ERROR: email Subject line not found")

text_anchor = "        text: |-"
if text_anchor in config:
    config = config[:config.index(text_anchor)] + r'''        text: |-
          [InfraReady] {{ template "infraready.status.ko" . }} - 장애 상태 요약

          현재 발생 중인 문제: {{ len .Alerts.Firing }}건
          {{ range .Alerts.Firing }}
          ----------------------------------------
          장애 종류: {{ template "infraready.alertname.ko" . }}
          심각도: {{ .Labels.severity }}
          대상 시스템: {{ template "infraready.job.ko" . }}
          대상 주소: {{ .Labels.instance }} ({{ template "infraready.target.name" . }})
          발생 시각: {{ date "2006-01-02 15:04:05 MST" (tz "Asia/Seoul" .StartsAt) }}
          설명: {{ template "infraready.cause.ko" . }}
          {{ end }}

          이번에 해결된 문제: {{ len .Alerts.Resolved }}건
          {{ range .Alerts.Resolved }}
          ----------------------------------------
          장애 종류: {{ template "infraready.alertname.ko" . }}
          대상 주소: {{ .Labels.instance }} ({{ template "infraready.target.name" . }})
          복구 시각: {{ date "2006-01-02 15:04:05 MST" (tz "Asia/Seoul" .EndsAt) }}
          {{ end }}

          Grafana: http://192.168.14.73:3000/d/infraready-observability/infraready-observability?orgId=1
'''

config_path.write_text(config, encoding="utf-8")

template = template_path.read_text(encoding="utf-8")
anchor = '{{ define "infraready.email.html" }}'
if anchor not in template:
    raise SystemExit(f"ERROR: HTML template anchor not found: {anchor}")

html = r'''{{ define "infraready.email.html" }}
<!doctype html>
<html lang="ko">
  <body style="font-family:Arial,sans-serif;color:#222;line-height:1.55">
    <h2 style="margin-bottom:8px">[InfraReady] {{ template "infraready.status.ko" . }} - 장애 상태 요약</h2>
    <p style="margin-top:0;color:#555">
      현재 발생 중 <strong style="color:#c62828">{{ len .Alerts.Firing }}건</strong> ·
      이번에 복구 <strong style="color:#2e7d32">{{ len .Alerts.Resolved }}건</strong>
    </p>

    <h3 style="margin-top:24px;color:#c62828">현재 발생 중인 문제 정보</h3>
    {{ if gt (len .Alerts.Firing) 0 }}
      {{ range .Alerts.Firing }}
      <div style="border:1px solid #ef9a9a;border-left:5px solid #c62828;border-radius:6px;padding:14px;margin:12px 0;background:#fff8f8">
        <div><strong>상태:</strong> 장애 발생</div>
        <div><strong>장애 종류:</strong> {{ template "infraready.alertname.ko" . }}</div>
        <div><strong>심각도:</strong> {{ .Labels.severity }}</div>
        <div><strong>대상 시스템:</strong> {{ template "infraready.job.ko" . }}</div>
        <div><strong>대상 주소:</strong> {{ .Labels.instance }} ({{ template "infraready.target.name" . }})</div>
        <div><strong>발생 시각:</strong> {{ date "2006-01-02 15:04:05 MST" (tz "Asia/Seoul" .StartsAt) }}</div>
        <div style="margin-top:8px"><strong>설명:</strong><br>{{ template "infraready.cause.ko" . }}</div>
      </div>
      {{ end }}
    {{ else }}
      <div style="border:1px solid #a5d6a7;border-radius:6px;padding:14px;background:#f7fff7;color:#2e7d32">
        현재 발생 중인 문제가 없습니다.
      </div>
    {{ end }}

    <hr style="border:0;border-top:1px solid #bbb;margin:28px 0">

    <h3 style="color:#2e7d32">이번에 해결된 문제 정보</h3>
    {{ if gt (len .Alerts.Resolved) 0 }}
      {{ range .Alerts.Resolved }}
      <div style="border:1px solid #a5d6a7;border-left:5px solid #2e7d32;border-radius:6px;padding:14px;margin:12px 0;background:#f7fff7">
        <div><strong>상태:</strong> 복구 완료</div>
        <div><strong>장애 종류:</strong> {{ template "infraready.alertname.ko" . }}</div>
        <div><strong>대상 시스템:</strong> {{ template "infraready.job.ko" . }}</div>
        <div><strong>대상 주소:</strong> {{ .Labels.instance }} ({{ template "infraready.target.name" . }})</div>
        <div><strong>발생 시각:</strong> {{ date "2006-01-02 15:04:05 MST" (tz "Asia/Seoul" .StartsAt) }}</div>
        <div><strong>복구 시각:</strong> {{ date "2006-01-02 15:04:05 MST" (tz "Asia/Seoul" .EndsAt) }}</div>
      </div>
      {{ end }}
    {{ else }}
      <p style="color:#666">이번 알림에서 새로 복구된 문제는 없습니다.</p>
    {{ end }}

    <p style="margin-top:24px">
      <a href="http://192.168.14.73:3000/d/infraready-observability/infraready-observability?orgId=1"
         style="display:inline-block;background:#3871dc;color:#fff;text-decoration:none;padding:10px 16px;border-radius:4px">
        Grafana에서 확인
      </a>
    </p>
    <p style="color:#666;font-size:12px">PC6 Monitoring VM의 Alertmanager에서 발송한 장애 상태 요약입니다.</p>
  </body>
</html>
{{ end }}
'''

# infraready.email.html은 템플릿 파일의 마지막 정의이므로 해당 위치부터 교체한다.
template = template[:template.index(anchor)] + html
template_path.write_text(template, encoding="utf-8")
PY

chown root:root "$ALERT_CONFIG" "$TEMPLATE_FILE"
chmod 0644 "$ALERT_CONFIG" "$TEMPLATE_FILE"

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
  exit 5
fi

echo '[4/6] Alertmanager를 재시작하고 Ready 상태를 확인합니다.'
if ! systemctl restart alertmanager.service; then
  rollback
  echo 'ERROR: Alertmanager 재시작 실패. 기존 설정으로 복구했습니다.' >&2
  exit 6
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
  exit 7
fi

echo '[5/6] 장애 2개가 한 메일에 표시되는 시험 경보를 등록합니다.'
TEST_ID=$(date -u +%Y%m%dT%H%M%SZ)
STARTS_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENDS_AT=$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)

jq -n \
  --arg test_id "$TEST_ID" \
  --arg starts_at "$STARTS_AT" \
  --arg ends_at "$ENDS_AT" \
  '[
    {
      labels: {
        alertname: "TargetDown",
        severity: "critical",
        instance: "192.168.34.41:9100",
        node: "worker1",
        job: "node-exporter-k8s-existing",
        summary_test_id: $test_id
      },
      annotations: {
        summary: "장애 상태 요약 메일 worker1 시험",
        description: "worker1 시험 경보입니다."
      },
      startsAt: $starts_at,
      endsAt: $ends_at
    },
    {
      labels: {
        alertname: "MariaDBServiceDown",
        severity: "critical",
        instance: "192.168.44.52:9104",
        job: "mariadb",
        summary_test_id: $test_id
      },
      annotations: {
        summary: "장애 상태 요약 메일 db-replica 시험",
        description: "db-replica 시험 경보입니다."
      },
      startsAt: $starts_at,
      endsAt: $ends_at
    }
  ]' > "$TEST_JSON"

curl -fsS \
  -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "@$TEST_JSON" \
  http://127.0.0.1:9093/api/v2/alerts

echo '[6/6] 적용 결과를 확인합니다.'
grep -q '^  group_by: \[\]$' "$ALERT_CONFIG"
grep -q '현재 발생 중인 문제 정보' "$TEMPLATE_FILE"
grep -q '이번에 해결된 문제 정보' "$TEMPLATE_FILE"

echo 'ALERT_EMAIL_ACTIVE_SUMMARY_READY'
echo "TEST_ALERT_ID=$TEST_ID"
echo "CONFIG_BACKUP=$CONFIG_BACKUP"
echo "TEMPLATE_BACKUP=$TEMPLATE_BACKUP"
echo '약 30초 후 현재 발생 중 2건으로 표시되는 시험 메일을 확인하세요.'
echo '시험 경보는 10분 뒤 종료되며 복구 요약 메일이 한 번 발송됩니다.'
