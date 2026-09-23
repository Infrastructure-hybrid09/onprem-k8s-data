#!/usr/bin/env bash
set -Eeuo pipefail

ALERTMANAGER_URL='http://127.0.0.1:9093'
TEST_JSON=$(mktemp /tmp/alertmanager-email-test.XXXXXX.json)

cleanup() {
  rm -f -- "$TEST_JSON"
}
trap cleanup EXIT

for command_name in curl jq date; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 1
  }
done

curl -fsS "${ALERTMANAGER_URL}/-/ready" >/dev/null || {
  echo 'ERROR: Alertmanager가 Ready 상태가 아닙니다.' >&2
  exit 2
}

TEST_ID=$(date -u +%Y%m%dT%H%M%SZ)
STARTS_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENDS_AT=$(date -u -d '3 minutes' +%Y-%m-%dT%H:%M:%SZ)

jq -n \
  --arg test_id "$TEST_ID" \
  --arg starts_at "$STARTS_AT" \
  --arg ends_at "$ENDS_AT" \
  '[{
    labels: {
      alertname: "GmailDeliveryTest",
      severity: "warning",
      instance: "127.0.0.1:9093",
      job: "alertmanager",
      test_id: $test_id
    },
    annotations: {
      summary: "Alertmanager Gmail 발송 복구 확인",
      description: "Alertmanager 이메일 접근 권한 복구 후 전송한 시험 경보입니다."
    },
    startsAt: $starts_at,
    endsAt: $ends_at
  }]' > "$TEST_JSON"

curl -fsS \
  -H 'Content-Type: application/json' \
  -X POST \
  --data-binary "@$TEST_JSON" \
  "${ALERTMANAGER_URL}/api/v2/alerts"

echo 'ALERTMANAGER_EMAIL_TEST_REGISTERED'
echo "TEST_ID=$TEST_ID"
echo '약 30초 후 장애 발생 시험 메일이 발송됩니다.'
echo '3분 뒤 시험 경보가 종료되고 복구 메일이 발송됩니다.'
