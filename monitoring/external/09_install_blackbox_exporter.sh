#!/usr/bin/env bash
set -Eeuo pipefail

BLACKBOX_IMAGE='quay.io/prometheus/blackbox-exporter:v0.28.0'
PROMETHEUS_IMAGE='quay.io/prometheus/prometheus:v3.13.1-distroless'
BLACKBOX_CONFIG='/etc/blackbox_exporter/blackbox.yml'
BLACKBOX_UNIT='/etc/systemd/system/blackbox-exporter.service'
PROMETHEUS_CONFIG='/etc/prometheus/prometheus.yml'
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PROMETHEUS_BACKUP="${PROMETHEUS_CONFIG}.before-blackbox-${TIMESTAMP}"
TEMP_CONFIG=$(mktemp /etc/prometheus/prometheus.yml.blackbox.XXXXXX)

cleanup() {
  rm -f -- "$TEMP_CONFIG"
}
trap cleanup EXIT

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

for command_name in podman curl awk systemctl; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 2
  }
done

[[ -s "$PROMETHEUS_CONFIG" ]] || {
  echo "ERROR: Prometheus 설정 파일이 없습니다: $PROMETHEUS_CONFIG" >&2
  exit 3
}

echo '[1/7] Worker NodePort의 Frontend/Backend를 사전 확인합니다.'
for ip in 192.168.34.41 192.168.34.42 192.168.34.43; do
  for path_name in / /api/health; do
    http_code=$(
      curl -k -sS \
        --connect-timeout 5 \
        --max-time 10 \
        --resolve "app.nplan.local:30443:${ip}" \
        -o /dev/null \
        -w '%{http_code}' \
        "https://app.nplan.local:30443${path_name}"
    )
    if [[ "$http_code" != '200' ]]; then
      echo "ERROR: 사전 점검 실패: ${ip}${path_name} HTTP=${http_code}" >&2
      exit 4
    fi
    echo "PRECHECK_OK ip=${ip} path=${path_name} http=200"
  done
done

echo '[2/7] Blackbox Exporter 이미지를 준비합니다.'
if ! podman image exists "$BLACKBOX_IMAGE"; then
  podman pull "$BLACKBOX_IMAGE"
fi

echo '[3/7] Blackbox Exporter 설정과 systemd 서비스를 설치합니다.'
install -d -o root -g root -m 0755 /etc/blackbox_exporter

if [[ -e "$BLACKBOX_CONFIG" ]]; then
  cp -a -- "$BLACKBOX_CONFIG" "${BLACKBOX_CONFIG}.before-${TIMESTAMP}"
fi
if [[ -e "$BLACKBOX_UNIT" ]]; then
  cp -a -- "$BLACKBOX_UNIT" "${BLACKBOX_UNIT}.before-${TIMESTAMP}"
fi

cat > "$BLACKBOX_CONFIG" <<'EOF'
modules:
  http_2xx_neuroplan:
    prober: http
    timeout: 10s
    http:
      method: GET
      valid_status_codes:
        - 200
      preferred_ip_protocol: ip4
      follow_redirects: true
      headers:
        Host: app.nplan.local
      tls_config:
        server_name: app.nplan.local
        insecure_skip_verify: true
EOF
chmod 0644 "$BLACKBOX_CONFIG"

cat > "$BLACKBOX_UNIT" <<EOF
[Unit]
Description=Prometheus Blackbox Exporter container
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStartPre=-/usr/bin/podman rm -f blackbox-exporter
ExecStart=/usr/bin/podman run --name blackbox-exporter --rm --network host --security-opt=no-new-privileges -v /etc/blackbox_exporter:/etc/blackbox_exporter:ro,Z ${BLACKBOX_IMAGE} --config.file=/etc/blackbox_exporter/blackbox.yml --web.listen-address=127.0.0.1:9115
ExecStop=/usr/bin/podman stop -t 30 blackbox-exporter
TimeoutStopSec=45

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now blackbox-exporter.service

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9115/metrics >/dev/null; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:9115/metrics >/dev/null || {
  systemctl --no-pager --full status blackbox-exporter.service || true
  echo 'ERROR: Blackbox Exporter가 준비되지 않았습니다.' >&2
  exit 5
}

echo '[4/7] Blackbox Exporter를 통해 6개 엔드포인트를 직접 검사합니다.'
for ip in 192.168.34.41 192.168.34.42 192.168.34.43; do
  for path_name in / /api/health; do
    probe_result=$(
      curl -fsSG http://127.0.0.1:9115/probe \
        --data-urlencode 'module=http_2xx_neuroplan' \
        --data-urlencode "target=https://${ip}:30443${path_name}"
    )
    probe_success=$(awk '$1 == "probe_success" {print $2}' <<<"$probe_result")
    http_status=$(awk '$1 == "probe_http_status_code" {print $2}' <<<"$probe_result")
    if [[ "$probe_success" != '1' || "$http_status" != '200' ]]; then
      echo "ERROR: Blackbox 점검 실패: ${ip}${path_name} success=${probe_success:-none} http=${http_status:-none}" >&2
      exit 6
    fi
    echo "PROBE_OK ip=${ip} path=${path_name} success=1 http=200"
  done
done

echo '[5/7] Prometheus 설정에 Blackbox 점검 Job을 추가합니다.'
cp -a -- "$PROMETHEUS_CONFIG" "$PROMETHEUS_BACKUP"

awk '
  /^  # BEGIN INFRAREADY BLACKBOX$/ { skip=1; next }
  /^  # END INFRAREADY BLACKBOX$/   { skip=0; next }
  !skip { print }
' "$PROMETHEUS_CONFIG" > "$TEMP_CONFIG"

cat >> "$TEMP_CONFIG" <<'EOF'

  # BEGIN INFRAREADY BLACKBOX
  # Monitoring VM -> Main K8s Worker Internal NodePort 서비스 점검
  - job_name: blackbox-neuroplan
    scrape_interval: 30s
    scrape_timeout: 15s
    metrics_path: /probe
    params:
      module:
        - http_2xx_neuroplan
    static_configs:
      - targets:
          - https://192.168.34.41:30443/
        labels:
          site: main
          node: worker1
          endpoint_type: frontend
      - targets:
          - https://192.168.34.41:30443/api/health
        labels:
          site: main
          node: worker1
          endpoint_type: backend
      - targets:
          - https://192.168.34.42:30443/
        labels:
          site: main
          node: worker2
          endpoint_type: frontend
      - targets:
          - https://192.168.34.42:30443/api/health
        labels:
          site: main
          node: worker2
          endpoint_type: backend
      - targets:
          - https://192.168.34.43:30443/
        labels:
          site: main
          node: worker3
          endpoint_type: frontend
      - targets:
          - https://192.168.34.43:30443/api/health
        labels:
          site: main
          node: worker3
          endpoint_type: backend
    relabel_configs:
      - source_labels:
          - __address__
        target_label: __param_target
      - source_labels:
          - __param_target
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115
  # END INFRAREADY BLACKBOX
EOF

chown root:root "$TEMP_CONFIG"
chmod 0644 "$TEMP_CONFIG"

TEMP_BASENAME=$(basename -- "$TEMP_CONFIG")
podman run \
  --rm \
  --entrypoint=/bin/promtool \
  -v /etc/prometheus:/etc/prometheus:ro,Z \
  "$PROMETHEUS_IMAGE" \
  check config \
  "/etc/prometheus/$TEMP_BASENAME"

install -o root -g root -m 0644 "$TEMP_CONFIG" "$PROMETHEUS_CONFIG"

echo '[6/7] Prometheus를 재시작하고 Ready 상태를 확인합니다.'
if ! systemctl restart prometheus.service; then
  cp -a -- "$PROMETHEUS_BACKUP" "$PROMETHEUS_CONFIG"
  systemctl restart prometheus.service || true
  echo "ERROR: Prometheus 재시작 실패. 설정을 복구했습니다: $PROMETHEUS_BACKUP" >&2
  exit 7
fi

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9090/-/ready >/dev/null; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:9090/-/ready >/dev/null || {
  cp -a -- "$PROMETHEUS_BACKUP" "$PROMETHEUS_CONFIG"
  systemctl restart prometheus.service || true
  echo "ERROR: Prometheus Ready 실패. 설정을 복구했습니다: $PROMETHEUS_BACKUP" >&2
  exit 8
}

echo '[7/7] Prometheus가 한 번 수집할 때까지 기다린 후 결과를 확인합니다.'
sleep 35

failed_count=$(
  curl -fsS http://127.0.0.1:9090/api/v1/targets |
    jq '[.data.activeTargets[] | select(.labels.job == "blackbox-neuroplan" and .health != "up")] | length'
)
target_count=$(
  curl -fsS http://127.0.0.1:9090/api/v1/targets |
    jq '[.data.activeTargets[] | select(.labels.job == "blackbox-neuroplan")] | length'
)

curl -fsS http://127.0.0.1:9090/api/v1/targets |
  jq -r '
    .data.activeTargets[]
    | select(.labels.job == "blackbox-neuroplan")
    | [.labels.node,.labels.endpoint_type,.labels.instance,.health,.lastError]
    | @tsv
  ' | sort

if [[ "$target_count" != '6' || "$failed_count" != '0' ]]; then
  echo "ERROR: Blackbox Target 검증 실패: total=${target_count}, failed=${failed_count}" >&2
  exit 9
fi

probe_failure_count=$(
  curl -fsSG http://127.0.0.1:9090/api/v1/query \
    --data-urlencode 'query=count(probe_success{job="blackbox-neuroplan"} != 1)' |
    jq -r '.data.result[0].value[1] // "0"'
)

if [[ "$probe_failure_count" != '0' ]]; then
  echo "ERROR: probe_success 실패 대상 수: $probe_failure_count" >&2
  exit 10
fi

echo 'BLACKBOX_MONITORING_READY'
echo 'BLACKBOX_TARGETS=6'
echo "PROMETHEUS_CONFIG_BACKUP=$PROMETHEUS_BACKUP"
