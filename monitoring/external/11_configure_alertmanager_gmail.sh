#!/usr/bin/env bash
set -Eeuo pipefail

ALERTMANAGER_IMAGE='quay.io/prometheus/alertmanager:v0.33.1'
CONFIG='/etc/alertmanager/alertmanager.yml'
SECRET_DIR='/etc/alertmanager/secrets'
PASSWORD_FILE="${SECRET_DIR}/gmail-app-password"
STAMP=$(date +%Y%m%d-%H%M%S)
CONFIG_BACKUP="${CONFIG}.before-gmail-${STAMP}"
PASSWORD_BACKUP="${PASSWORD_FILE}.before-${STAMP}"
TEST_JSON=$(mktemp /tmp/alertmanager-gmail-test.XXXXXX.json)
PASSWORD_EXISTED=false

cleanup() {
  unset GMAIL_APP_PASSWORD GMAIL_APP_PASSWORD_CONFIRM
  rm -f -- "$TEST_JSON"
}
trap cleanup EXIT

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

for command_name in podman curl jq nc getent systemctl; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 2
  }
done

[[ -s "$CONFIG" ]] || {
  echo "ERROR: Alertmanager 설정 파일이 없습니다: $CONFIG" >&2
  exit 3
}

echo '[1/7] Gmail SMTP DNS와 포트 연결을 확인합니다.'
getent ahostsv4 smtp.gmail.com | head -n 1
nc -vz -w 10 smtp.gmail.com 587

echo '[2/7] Gmail 발신·수신 정보와 앱 비밀번호를 입력합니다.'
read -r -p 'Gmail 발신 주소: ' GMAIL_SENDER
[[ "$GMAIL_SENDER" == *@*.* ]] || {
  echo 'ERROR: Gmail 발신 주소 형식이 올바르지 않습니다.' >&2
  exit 4
}

read -r -p '알림 수신 주소 (Enter=발신 주소와 동일): ' GMAIL_RECIPIENT
GMAIL_RECIPIENT=${GMAIL_RECIPIENT:-$GMAIL_SENDER}
[[ "$GMAIL_RECIPIENT" == *@*.* ]] || {
  echo 'ERROR: 알림 수신 주소 형식이 올바르지 않습니다.' >&2
  exit 5
}

read -r -s -p 'Google 16자리 앱 비밀번호: ' GMAIL_APP_PASSWORD
echo
read -r -s -p 'Google 앱 비밀번호 재입력: ' GMAIL_APP_PASSWORD_CONFIRM
echo

# Google 화면에서 네 자리씩 표시되는 공백은 저장 전에 제거한다.
GMAIL_APP_PASSWORD=${GMAIL_APP_PASSWORD//[[:space:]]/}
GMAIL_APP_PASSWORD_CONFIRM=${GMAIL_APP_PASSWORD_CONFIRM//[[:space:]]/}

[[ "$GMAIL_APP_PASSWORD" == "$GMAIL_APP_PASSWORD_CONFIRM" ]] || {
  echo 'ERROR: 앱 비밀번호가 서로 일치하지 않습니다.' >&2
  exit 6
}
[[ ${#GMAIL_APP_PASSWORD} -eq 16 ]] || {
  echo 'ERROR: 공백을 제외한 앱 비밀번호 길이는 16자리여야 합니다.' >&2
  exit 7
}

echo '[3/7] 비밀번호 파일과 Alertmanager 설정을 백업·적용합니다.'
cp -a -- "$CONFIG" "$CONFIG_BACKUP"
install -d -o root -g 65534 -m 0750 "$SECRET_DIR"

if [[ -e "$PASSWORD_FILE" ]]; then
  PASSWORD_EXISTED=true
  cp -a -- "$PASSWORD_FILE" "$PASSWORD_BACKUP"
fi

umask 077
printf '%s' "$GMAIL_APP_PASSWORD" > "$PASSWORD_FILE"
chown root:65534 "$PASSWORD_FILE"
chmod 0640 "$PASSWORD_FILE"
unset GMAIL_APP_PASSWORD GMAIL_APP_PASSWORD_CONFIRM

cat > "$CONFIG" <<EOF
global:
  resolve_timeout: 5m
  smtp_from: '${GMAIL_SENDER}'
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_hello: 'monitoring.nplan.local'
  smtp_auth_username: '${GMAIL_SENDER}'
  smtp_auth_password_file: '/etc/alertmanager/secrets/gmail-app-password'
  smtp_require_tls: true

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
      - to: '${GMAIL_RECIPIENT}'
        from: '${GMAIL_SENDER}'
        send_resolved: true
        headers:
          Subject: '[InfraReady] {{ .Status }} - {{ .CommonLabels.alertname }}'
        text: |-
          상태: {{ .Status }}
          경보: {{ .CommonLabels.alertname }}
          심각도: {{ .CommonLabels.severity }}
          대상: {{ .CommonLabels.instance }}
          요약: {{ .CommonAnnotations.summary }}
          설명: {{ .CommonAnnotations.description }}
EOF

chown root:root "$CONFIG"
chmod 0644 "$CONFIG"

echo '[4/7] Alertmanager 설정 구문과 비밀번호 파일 접근을 검증합니다.'
if ! podman run \
  --rm \
  --entrypoint=/bin/amtool \
  -v /etc/alertmanager:/etc/alertmanager:ro,Z \
  "$ALERTMANAGER_IMAGE" \
  check-config \
  /etc/alertmanager/alertmanager.yml; then
  cp -a -- "$CONFIG_BACKUP" "$CONFIG"
  if $PASSWORD_EXISTED; then
    cp -a -- "$PASSWORD_BACKUP" "$PASSWORD_FILE"
  else
    rm -f -- "$PASSWORD_FILE"
  fi
  echo 'ERROR: 설정 검증 실패. 기존 설정으로 복구했습니다.' >&2
  exit 8
fi

echo '[5/7] Alertmanager를 재시작하고 Ready 상태를 확인합니다.'
if ! systemctl restart alertmanager.service; then
  cp -a -- "$CONFIG_BACKUP" "$CONFIG"
  if $PASSWORD_EXISTED; then
    cp -a -- "$PASSWORD_BACKUP" "$PASSWORD_FILE"
  else
    rm -f -- "$PASSWORD_FILE"
  fi
  systemctl restart alertmanager.service || true
  echo 'ERROR: Alertmanager 재시작 실패. 기존 설정으로 복구했습니다.' >&2
  exit 9
fi

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9093/-/ready >/dev/null; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:9093/-/ready >/dev/null || {
  echo 'ERROR: Alertmanager Ready 확인 실패.' >&2
  exit 10
}

echo '[6/7] Gmail 발송 시험용 경보를 Alertmanager에 등록합니다.'
TEST_ID=$(date -u +%Y%m%dT%H%M%SZ)
STARTS_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENDS_AT=$(date -u -d '+15 minutes' +%Y-%m-%dT%H:%M:%SZ)

jq -n \
  --arg test_id "$TEST_ID" \
  --arg starts_at "$STARTS_AT" \
  --arg ends_at "$ENDS_AT" \
  '[{
    labels: {
      alertname: "GmailDeliveryTest",
      severity: "warning",
      instance: "monitoring-pc6",
      test_id: $test_id
    },
    annotations: {
      summary: "Alertmanager Gmail 발송 시험",
      description: "PC6 Alertmanager에서 전송한 시험 경보입니다."
    },
    startsAt: $starts_at,
    endsAt: $ends_at,
    generatorURL: "http://127.0.0.1:9090/alerts"
  }]' > "$TEST_JSON"

curl -fsS \
  -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "@$TEST_JSON" \
  http://127.0.0.1:9093/api/v2/alerts

echo "TEST_ALERT_ID=$TEST_ID"
echo 'group_wait 30초와 SMTP 처리 시간을 기다립니다.'
sleep 40

echo '[7/7] 알림 처리 결과를 확인합니다.'
curl -fsS http://127.0.0.1:9093/metrics |
  grep -E '^alertmanager_notifications_(total|failed_total).*integration="email"' || true

recent_errors=$(
  journalctl -u alertmanager.service --since '-2 minutes' --no-pager |
    grep -Eic 'notify retry canceled|level=error|smtp.*error|authentication failed' || true
)

if [[ "$recent_errors" != '0' ]]; then
  echo 'WARNING: 최근 Alertmanager 로그에 발송 오류가 있습니다.' >&2
  journalctl -u alertmanager.service --since '-2 minutes' --no-pager |
    grep -Ei 'notify retry canceled|level=error|smtp.*error|authentication failed' |
    tail -n 20 >&2 || true
  exit 11
fi

echo 'ALERTMANAGER_GMAIL_CONFIGURED'
echo "SENDER=$GMAIL_SENDER"
echo "RECIPIENT=$GMAIL_RECIPIENT"
echo "CONFIG_BACKUP=$CONFIG_BACKUP"
echo '수신함과 스팸함에서 [InfraReady] firing - GmailDeliveryTest 메일을 확인하세요.'
