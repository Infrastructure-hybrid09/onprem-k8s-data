#!/usr/bin/env bash
set -Eeuo pipefail

ALERTMANAGER_IMAGE='quay.io/prometheus/alertmanager:v0.33.1'
CONFIG='/etc/alertmanager/alertmanager.yml'
TEMPLATE_DIR='/etc/alertmanager/templates'
TEMPLATE_FILE="${TEMPLATE_DIR}/infraready-email.tmpl"
GRAFANA_URL='http://192.168.14.73:3000/d/infraready-observability/infraready-observability?orgId=1'
STAMP=$(date +%Y%m%d-%H%M%S)
CONFIG_BACKUP="${CONFIG}.before-custom-email-${STAMP}"
TEMPLATE_BACKUP="${TEMPLATE_FILE}.before-${STAMP}"
TEST_JSON=$(mktemp /tmp/alertmanager-email-template-test.XXXXXX.json)
TEMPLATE_EXISTED=false

cleanup() {
  rm -f -- "$TEST_JSON"
}
trap cleanup EXIT

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

for command_name in podman curl jq sed systemctl; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 2
  }
done

[[ -s "$CONFIG" ]] || {
  echo "ERROR: Alertmanager 설정 파일이 없습니다: $CONFIG" >&2
  exit 3
}
[[ -s /etc/alertmanager/secrets/gmail-app-password ]] || {
  echo 'ERROR: Gmail 앱 비밀번호 파일이 없습니다.' >&2
  exit 4
}

SENDER=$(
  sed -nE "s/^[[:space:]]*smtp_from:[[:space:]]*'([^']+)'/\1/p" "$CONFIG" |
    head -n 1
)
RECIPIENT=$(
  sed -nE "s/^[[:space:]]*- to:[[:space:]]*'([^']+)'/\1/p" "$CONFIG" |
    head -n 1
)

[[ "$SENDER" == *@*.* && "$RECIPIENT" == *@*.* ]] || {
  echo 'ERROR: 현재 Alertmanager 설정에서 Gmail 발신·수신 주소를 읽지 못했습니다.' >&2
  exit 5
}

echo '[1/6] 현재 Gmail 설정과 템플릿을 백업합니다.'
cp -a -- "$CONFIG" "$CONFIG_BACKUP"
install -d -o root -g root -m 0755 "$TEMPLATE_DIR"
if [[ -e "$TEMPLATE_FILE" ]]; then
  TEMPLATE_EXISTED=true
  cp -a -- "$TEMPLATE_FILE" "$TEMPLATE_BACKUP"
fi

echo '[2/6] 내부 Alertmanager 링크를 제외한 이메일 템플릿을 설치합니다.'
cat > "$TEMPLATE_FILE" <<'EOF'
{{ define "infraready.email.html" }}
<!doctype html>
<html lang="ko">
  <body style="font-family:Arial,sans-serif;color:#222;line-height:1.5">
    <h2 style="margin-bottom:8px">[InfraReady] {{ .Status }} - {{ .CommonLabels.alertname }}</h2>
    <p style="margin-top:0">심각도: <strong>{{ .CommonLabels.severity }}</strong></p>
    {{ range .Alerts }}
    <div style="border:1px solid #ddd;border-radius:6px;padding:12px;margin:12px 0">
      <div><strong>상태:</strong> {{ .Status }}</div>
      <div><strong>대상:</strong> {{ .Labels.instance }}</div>
      <div><strong>Job:</strong> {{ .Labels.job }}</div>
      <div><strong>요약:</strong> {{ .Annotations.summary }}</div>
      <div><strong>설명:</strong> {{ .Annotations.description }}</div>
    </div>
    {{ end }}
    <p style="margin-top:20px">
      <a href="http://192.168.14.73:3000/d/infraready-observability/infraready-observability?orgId=1"
         style="display:inline-block;background:#3871dc;color:#fff;text-decoration:none;padding:10px 16px;border-radius:4px">
        Grafana에서 확인
      </a>
    </p>
    <p style="color:#666;font-size:12px">
      PC6 Monitoring VM의 Alertmanager에서 발송한 알림입니다.
    </p>
  </body>
</html>
{{ end }}
EOF
chown root:root "$TEMPLATE_FILE"
chmod 0644 "$TEMPLATE_FILE"

echo '[3/6] Alertmanager 설정에 사용자 이메일 템플릿을 적용합니다.'
cat > "$CONFIG" <<EOF
global:
  resolve_timeout: 5m
  smtp_from: '${SENDER}'
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_hello: 'monitoring.nplan.local'
  smtp_auth_username: '${SENDER}'
  smtp_auth_password_file: '/etc/alertmanager/secrets/gmail-app-password'
  smtp_require_tls: true

templates:
  - '/etc/alertmanager/templates/*.tmpl'

route:
  receiver: gmail-email
  group_by:
    - alertname
    - severity
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: gmail-email
    email_configs:
      - to: '${RECIPIENT}'
        from: '${SENDER}'
        send_resolved: true
        headers:
          Subject: '[InfraReady] {{ .Status }} - {{ .CommonLabels.alertname }}'
        html: '{{ template "infraready.email.html" . }}'
        text: |-
          상태: {{ .Status }}
          경보: {{ .CommonLabels.alertname }}
          심각도: {{ .CommonLabels.severity }}
          대상: {{ .CommonLabels.instance }}
          요약: {{ .CommonAnnotations.summary }}
          설명: {{ .CommonAnnotations.description }}
          Grafana: ${GRAFANA_URL}
EOF
chown root:root "$CONFIG"
chmod 0644 "$CONFIG"

echo '[4/6] 설정과 템플릿 구문을 검증합니다.'
if ! podman run \
  --rm \
  --entrypoint=/bin/amtool \
  -v /etc/alertmanager:/etc/alertmanager:ro,Z \
  "$ALERTMANAGER_IMAGE" \
  check-config \
  /etc/alertmanager/alertmanager.yml; then
  cp -a -- "$CONFIG_BACKUP" "$CONFIG"
  if $TEMPLATE_EXISTED; then
    cp -a -- "$TEMPLATE_BACKUP" "$TEMPLATE_FILE"
  else
    rm -f -- "$TEMPLATE_FILE"
  fi
  echo 'ERROR: 설정 검증 실패. 기존 상태로 복구했습니다.' >&2
  exit 6
fi

echo '[5/6] Alertmanager를 재시작하고 Ready 상태를 확인합니다.'
if ! systemctl restart alertmanager.service; then
  cp -a -- "$CONFIG_BACKUP" "$CONFIG"
  if $TEMPLATE_EXISTED; then
    cp -a -- "$TEMPLATE_BACKUP" "$TEMPLATE_FILE"
  else
    rm -f -- "$TEMPLATE_FILE"
  fi
  systemctl restart alertmanager.service || true
  echo 'ERROR: Alertmanager 재시작 실패. 기존 상태로 복구했습니다.' >&2
  exit 7
fi

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9093/-/ready >/dev/null; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:9093/-/ready >/dev/null || {
  echo 'ERROR: Alertmanager Ready 확인 실패.' >&2
  exit 8
}

echo '[6/6] 새 템플릿 확인용 시험 메일을 요청합니다.'
TEST_ID=$(date -u +%Y%m%dT%H%M%SZ)
STARTS_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENDS_AT=$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)

jq -n \
  --arg test_id "$TEST_ID" \
  --arg starts_at "$STARTS_AT" \
  --arg ends_at "$ENDS_AT" \
  '[{
    labels: {
      alertname: "GmailTemplateTest",
      severity: "warning",
      instance: "monitoring-pc6",
      job: "alertmanager",
      test_id: $test_id
    },
    annotations: {
      summary: "Grafana 링크 이메일 템플릿 시험",
      description: "메일의 Grafana에서 확인 버튼을 검증하는 시험 경보입니다."
    },
    startsAt: $starts_at,
    endsAt: $ends_at
  }]' > "$TEST_JSON"

curl -fsS \
  -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "@$TEST_JSON" \
  http://127.0.0.1:9093/api/v2/alerts

echo 'ALERTMANAGER_EMAIL_TEMPLATE_READY'
echo "TEST_ALERT_ID=$TEST_ID"
echo "GRAFANA_URL=$GRAFANA_URL"
echo "CONFIG_BACKUP=$CONFIG_BACKUP"
echo '약 30초 후 Gmail에서 [InfraReady] firing - GmailTemplateTest를 확인하세요.'
