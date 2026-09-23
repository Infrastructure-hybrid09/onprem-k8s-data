#!/usr/bin/env bash
set -Eeuo pipefail

PROMETHEUS_IMAGE='quay.io/prometheus/prometheus:v3.13.1-distroless'
RULE_FILE='/etc/prometheus/rules/mariadb-service-alert.yml'
STAMP=$(date +%Y%m%d-%H%M%S)
RULE_BACKUP="${RULE_FILE}.before-${STAMP}"
RULE_EXISTED=false

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

for command_name in podman curl jq systemctl; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 2
  }
done

echo '[1/5] MariaDB 서비스 상태 메트릭을 확인합니다.'
mysql_up_count=$(
  curl -fsSG http://127.0.0.1:9090/api/v1/query \
    --data-urlencode 'query=count(mysql_up{job="mariadb"})' |
    jq -r '.data.result[0].value[1] // "0"'
)
mysql_healthy_count=$(
  curl -fsSG http://127.0.0.1:9090/api/v1/query \
    --data-urlencode 'query=count(mysql_up{job="mariadb"} == 1)' |
    jq -r '.data.result[0].value[1] // "0"'
)

[[ "$mysql_up_count" == '2' && "$mysql_healthy_count" == '2' ]] || {
  echo "ERROR: MariaDB 상태가 예상과 다릅니다: metrics=${mysql_up_count}, healthy=${mysql_healthy_count}" >&2
  exit 3
}
echo 'MARIADB_PRECHECK_OK metrics=2 healthy=2'

echo '[2/5] MariaDB 서비스 장애 경보를 설치합니다.'
if [[ -e "$RULE_FILE" ]]; then
  RULE_EXISTED=true
  cp -a -- "$RULE_FILE" "$RULE_BACKUP"
fi

cat > "$RULE_FILE" <<'EOF'
groups:
  - name: infraready.mariadb-service
    interval: 30s
    rules:
      - alert: MariaDBServiceDown
        expr: mysql_up{job="mariadb"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "MariaDB 서비스 접속 실패: {{ $labels.instance }}"
          description: "MariaDB Exporter는 응답하지만 대상 DB 접속이 1분 이상 실패했습니다."
EOF

chown root:root "$RULE_FILE"
chmod 0644 "$RULE_FILE"

echo '[3/5] 경보 규칙 구문을 검증합니다.'
if ! podman run \
  --rm \
  --entrypoint=/bin/promtool \
  -v /etc/prometheus:/etc/prometheus:ro,Z \
  "$PROMETHEUS_IMAGE" \
  check rules \
  /etc/prometheus/rules/mariadb-service-alert.yml; then
  if $RULE_EXISTED; then
    cp -a -- "$RULE_BACKUP" "$RULE_FILE"
  else
    rm -f -- "$RULE_FILE"
  fi
  echo 'ERROR: 규칙 검증 실패. 기존 상태로 복구했습니다.' >&2
  exit 4
fi

echo '[4/5] Prometheus를 재시작하고 규칙 평가를 기다립니다.'
if ! systemctl restart prometheus.service; then
  if $RULE_EXISTED; then
    cp -a -- "$RULE_BACKUP" "$RULE_FILE"
  else
    rm -f -- "$RULE_FILE"
  fi
  systemctl restart prometheus.service || true
  echo 'ERROR: Prometheus 재시작 실패. 기존 상태로 복구했습니다.' >&2
  exit 5
fi

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9090/-/ready >/dev/null; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:9090/-/ready >/dev/null || {
  echo 'ERROR: Prometheus Ready 확인 실패.' >&2
  exit 6
}

sleep 35

echo '[5/5] MariaDB 서비스 경보 상태를 확인합니다.'
rule_result=$(
  curl -fsS 'http://127.0.0.1:9090/api/v1/rules?type=alert' |
    jq -r '
      .data.groups[].rules[]
      | select(.name == "MariaDBServiceDown")
      | [.name,.state,.health,.labels.severity]
      | @tsv
    '
)

[[ -n "$rule_result" ]] || {
  echo 'ERROR: MariaDBServiceDown 규칙을 찾을 수 없습니다.' >&2
  exit 7
}
printf '%s\n' "$rule_result"

echo 'MARIADB_SERVICE_ALERT_READY'
if $RULE_EXISTED; then
  echo "RULE_BACKUP=$RULE_BACKUP"
fi
