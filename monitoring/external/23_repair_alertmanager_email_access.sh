#!/usr/bin/env bash
set -Eeuo pipefail

ALERT_DIR='/etc/alertmanager'
ALERT_CONFIG="${ALERT_DIR}/alertmanager.yml"
TEMPLATE_FILE="${ALERT_DIR}/templates/infraready-email.tmpl"
SECRET_DIR="${ALERT_DIR}/secrets"
PASSWORD_FILE="${SECRET_DIR}/gmail-app-password"
FIX_STARTED=$(date '+%Y-%m-%d %H:%M:%S')

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

for command_name in podman jq chcon curl journalctl; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 2
  }
done

for required_file in "$ALERT_CONFIG" "$TEMPLATE_FILE" "$PASSWORD_FILE"; do
  [[ -s "$required_file" ]] || {
    echo "ERROR: 필수 파일이 없거나 비어 있습니다: $required_file" >&2
    exit 3
  }
done

podman inspect alertmanager >/dev/null 2>&1 || {
  echo 'ERROR: 실행 중인 alertmanager 컨테이너를 찾지 못했습니다.' >&2
  exit 4
}

MOUNT_LABEL=$(
  podman inspect alertmanager |
    jq -r '.[0].MountLabel // empty'
)

[[ -n "$MOUNT_LABEL" && "$MOUNT_LABEL" == *container_file_t* ]] || {
  echo "ERROR: Alertmanager MountLabel을 확인하지 못했습니다: $MOUNT_LABEL" >&2
  exit 5
}

echo '[1/5] 현재 권한과 SELinux 라벨을 확인합니다.'
ls -Zd "$ALERT_DIR" "$ALERT_CONFIG" "$SECRET_DIR" "$PASSWORD_FILE"

echo '[2/5] 실행 중인 Alertmanager 컨테이너의 SELinux 라벨로 복구합니다.'
chcon -R "$MOUNT_LABEL" "$ALERT_DIR"

echo '[3/5] 파일 시스템 권한을 원래 보안 수준으로 복구합니다.'
chown root:root "$ALERT_CONFIG" "$TEMPLATE_FILE"
chmod 0644 "$ALERT_CONFIG" "$TEMPLATE_FILE"
chown root:65534 "$SECRET_DIR" "$PASSWORD_FILE"
chmod 0750 "$SECRET_DIR"
chmod 0640 "$PASSWORD_FILE"

echo '[4/5] 컨테이너를 재시작하지 않고 설정을 다시 읽습니다.'
podman kill --signal HUP alertmanager >/dev/null

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9093/-/ready >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

curl -fsS http://127.0.0.1:9093/-/ready >/dev/null || {
  echo 'ERROR: Alertmanager Ready 확인에 실패했습니다.' >&2
  exit 6
}

if journalctl \
  -u alertmanager.service \
  --since "$FIX_STARTED" \
  --no-pager |
  grep -Eqi 'permission denied|Loading configuration file failed'; then
  journalctl \
    -u alertmanager.service \
    --since "$FIX_STARTED" \
    --no-pager |
    grep -Ei 'permission denied|Loading configuration file failed' >&2 || true
  echo 'ERROR: 권한 오류가 계속 발생합니다.' >&2
  exit 7
fi

echo '[5/5] 복구된 권한과 발송 통계를 확인합니다.'
ls -Zd "$ALERT_CONFIG" "$PASSWORD_FILE"
curl -fsS http://127.0.0.1:9093/metrics |
  grep -E '^alertmanager_notifications_(total|failed_total).*integration="email"' || true

echo 'ALERTMANAGER_EMAIL_ACCESS_REPAIRED'
echo 'Alertmanager는 재시작하지 않았습니다. 대기 중인 메일은 다음 재시도에서 발송될 수 있습니다.'
