#!/usr/bin/env bash
set -Eeuo pipefail

PROMETHEUS_IMAGE='quay.io/prometheus/prometheus:v3.13.1-distroless'
CONFIG='/etc/prometheus/prometheus.yml'
CREDENTIAL_DIR='/etc/prometheus/credentials'
BACKUP="${CONFIG}.before-full-$(date +%Y%m%d-%H%M%S)"
TEMP_CONFIG=$(mktemp /etc/prometheus/prometheus.yml.XXXXXX)

cleanup() {
  rm -f -- "$TEMP_CONFIG"
}
trap cleanup EXIT

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

for file in main-ca.crt main-token dr-ca.crt dr-token; do
  if [[ ! -s "$CREDENTIAL_DIR/$file" ]]; then
    echo "ERROR: 인증 파일이 없거나 비어 있습니다: $CREDENTIAL_DIR/$file" >&2
    exit 1
  fi
done

cp -a -- "$CONFIG" "$BACKUP"

cat > "$TEMP_CONFIG" <<'EOF'
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    cluster: neuroplan-onprem

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - 127.0.0.1:9093

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  # PC6 Monitoring VM 자체 서비스
  - job_name: prometheus
    static_configs:
      - targets:
          - 127.0.0.1:9090

  - job_name: monitoring-node
    static_configs:
      - targets:
          - 127.0.0.1:9100
        labels:
          instance: monitoring
          site: pc6

  - job_name: grafana
    metrics_path: /metrics
    static_configs:
      - targets:
          - 192.168.14.73:3000
        labels:
          site: pc6

  - job_name: alertmanager
    static_configs:
      - targets:
          - 127.0.0.1:9093
        labels:
          site: pc6

  # 일반 VM Node Exporter
  - job_name: node-exporter-vm
    scrape_interval: 30s
    static_configs:
      - targets:
          - 192.168.14.11:9100
          - 192.168.14.12:9100
          - 192.168.14.21:9100
          - 192.168.14.51:9100
          - 192.168.14.52:9100
          - 192.168.14.61:9100
          - 192.168.14.62:9100
          - 192.168.14.72:9100
        labels:
          network: mgmt

  # Main K8s 6노드와 DR K3s Node Exporter
  - job_name: node-exporter-k8s-existing
    scrape_interval: 30s
    static_configs:
      - targets:
          - 192.168.34.31:9100
          - 192.168.34.32:9100
          - 192.168.34.33:9100
          - 192.168.34.41:9100
          - 192.168.34.42:9100
          - 192.168.34.43:9100
          - 192.168.34.71:9100
        labels:
          network: internal

  # MariaDB Exporter
  - job_name: mariadb
    scrape_interval: 15s
    static_configs:
      - targets:
          - 192.168.44.51:9104
          - 192.168.44.52:9104

  # Main K8s API Server
  - job_name: apiserver
    scrape_interval: 30s
    scheme: https
    metrics_path: /metrics
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/credentials/main-token
    tls_config:
      ca_file: /etc/prometheus/credentials/main-ca.crt
    static_configs:
      - targets:
          - 192.168.34.100:6443
        labels:
          site: main

  # Main K8s 오브젝트 상태
  - job_name: main-kube-state-metrics
    scrape_interval: 30s
    scheme: https
    metrics_path: /api/v1/namespaces/monitoring/services/monitoring-kube-state-metrics:8080/proxy/metrics
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/credentials/main-token
    tls_config:
      ca_file: /etc/prometheus/credentials/main-ca.crt
    static_configs:
      - targets:
          - 192.168.34.100:6443
        labels:
          site: main

  # Main Backend Actuator/Micrometer
  - job_name: main-backend
    scrape_interval: 30s
    scheme: https
    metrics_path: /api/v1/namespaces/application/services/neuroplan-backend:8080/proxy/actuator/prometheus
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/credentials/main-token
    tls_config:
      ca_file: /etc/prometheus/credentials/main-ca.crt
    static_configs:
      - targets:
          - 192.168.34.100:6443
        labels:
          site: main

  # Main K8s Loki 자체 메트릭
  - job_name: loki
    scrape_interval: 30s
    scheme: https
    metrics_path: /api/v1/namespaces/logging/services/loki:3100/proxy/metrics
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/credentials/main-token
    tls_config:
      ca_file: /etc/prometheus/credentials/main-ca.crt
    static_configs:
      - targets:
          - 192.168.34.100:6443
        labels:
          site: main

  # DR K3s Supervisor
  - job_name: dr-k3s-supervisor
    scrape_interval: 30s
    scheme: https
    metrics_path: /metrics
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/credentials/dr-token
    tls_config:
      ca_file: /etc/prometheus/credentials/dr-ca.crt
    static_configs:
      - targets:
          - 192.168.34.71:6443
        labels:
          site: pc6
          cluster: neuroplan-dr

  # DR K3s 오브젝트 상태
  - job_name: dr-kube-state-metrics
    scrape_interval: 30s
    scheme: https
    metrics_path: /api/v1/namespaces/monitoring/services/monitoring-kube-state-metrics:8080/proxy/metrics
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/credentials/dr-token
    tls_config:
      ca_file: /etc/prometheus/credentials/dr-ca.crt
    static_configs:
      - targets:
          - 192.168.34.71:6443
        labels:
          site: pc6
          cluster: neuroplan-dr

  # DR Backend Actuator/Micrometer
  - job_name: dr-backend
    scrape_interval: 30s
    scheme: https
    metrics_path: /api/v1/namespaces/application/services/neuroplan-backend:8080/proxy/actuator/prometheus
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/credentials/dr-token
    tls_config:
      ca_file: /etc/prometheus/credentials/dr-ca.crt
    static_configs:
      - targets:
          - 192.168.34.71:6443
        labels:
          site: pc6
          cluster: neuroplan-dr
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

install -o root -g root -m 0644 "$TEMP_CONFIG" "$CONFIG"

if ! systemctl restart prometheus.service; then
  cp -a -- "$BACKUP" "$CONFIG"
  systemctl restart prometheus.service || true
  echo "ERROR: 재시작 실패. 기존 설정으로 복구했습니다: $BACKUP" >&2
  exit 1
fi

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9090/-/ready >/dev/null; then
    echo 'PROMETHEUS_READY'
    echo "CONFIG_BACKUP=$BACKUP"
    echo
    echo '30초 후 다음 명령으로 Target 상태를 확인하세요.'
    echo "curl -s http://127.0.0.1:9090/api/v1/targets | jq -r '.data.activeTargets[] | [.labels.job,.scrapeUrl,.health,.lastError] | @tsv' | sort"
    exit 0
  fi
  sleep 1
done

cp -a -- "$BACKUP" "$CONFIG"
systemctl restart prometheus.service || true
echo "ERROR: Prometheus Ready 실패. 기존 설정으로 복구했습니다: $BACKUP" >&2
exit 1
