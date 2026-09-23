#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: run with sudo: sudo $0" >&2
  exit 2
fi

MGMT_IP=${MONITORING_MGMT_IP:-192.168.14.73}
PROM_IMAGE=quay.io/prometheus/prometheus:v3.13.1-distroless
GRAFANA_IMAGE=docker.io/grafana/grafana:13.1.1
ALERT_IMAGE=quay.io/prometheus/alertmanager:v0.33.1
NODE_IMAGE=quay.io/prometheus/node-exporter:v1.12.1

for command_name in podman findmnt ss firewall-cmd; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 3
  }
done

[[ $(hostname -s) == monitoring ]] || {
  echo "ERROR: expected hostname=monitoring, actual=$(hostname -s)" >&2
  exit 4
}

[[ $(findmnt -n -o TARGET /var/lib/prometheus 2>/dev/null || true) == /var/lib/prometheus ]] || {
  echo 'ERROR: /var/lib/prometheus is not a mounted filesystem.' >&2
  exit 5
}

[[ $(findmnt -n -o FSTYPE /var/lib/prometheus) == xfs ]] || {
  echo 'ERROR: /var/lib/prometheus must use XFS.' >&2
  exit 6
}

for port in 3000 9090 9093 9100; do
  if ss -H -lnt "sport = :$port" | grep -q .; then
    echo "ERROR: TCP port is already in use: $port" >&2
    exit 7
  fi
done

for image_name in "$PROM_IMAGE" "$GRAFANA_IMAGE" "$ALERT_IMAGE" "$NODE_IMAGE"; do
  podman image exists "$image_name" || {
    echo "ERROR: image is not present: $image_name" >&2
    exit 8
  }
done

install -d -o root -g root -m 0755 /etc/prometheus /etc/prometheus/rules
install -d -o root -g root -m 0755 /etc/alertmanager
install -d -o root -g root -m 0755 /etc/grafana/provisioning/datasources
install -d -o root -g root -m 0755 /etc/grafana/provisioning/dashboards
install -d -o 472 -g 472 -m 0750 /var/lib/grafana
install -d -o 472 -g 472 -m 0750 /var/lib/grafana/dashboards
install -d -o 65534 -g 65534 -m 0750 /var/lib/alertmanager
# The Prometheus distroless image runs as UID/GID 65532.
chown 65532:65532 /var/lib/prometheus
chmod 0750 /var/lib/prometheus
install -d -o root -g root -m 0700 /etc/monitoring

cat > /etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 30s
  evaluation_interval: 30s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - 127.0.0.1:9093

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
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

  - job_name: grafana
    metrics_path: /metrics
    static_configs:
      - targets:
          - ${MGMT_IP}:3000

  - job_name: alertmanager
    static_configs:
      - targets:
          - 127.0.0.1:9093
EOF

cat > /etc/alertmanager/alertmanager.yml <<'EOF'
global:
  resolve_timeout: 5m

route:
  receiver: default
  group_by:
    - alertname
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: default
EOF

cat > /etc/grafana/provisioning/datasources/prometheus.yaml <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
EOF

cat > /etc/grafana/provisioning/dashboards/infraready.yaml <<'EOF'
apiVersion: 1

providers:
  - name: InfraReady
    orgId: 1
    folder: InfraReady
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
EOF

chmod 0644 /etc/prometheus/prometheus.yml
chmod 0644 /etc/alertmanager/alertmanager.yml
chmod 0644 /etc/grafana/provisioning/datasources/prometheus.yaml
chmod 0644 /etc/grafana/provisioning/dashboards/infraready.yaml

if [[ ! -f /etc/monitoring/grafana.env ]]; then
  read -r -s -p 'Grafana admin password: ' GRAFANA_PASSWORD
  echo
  read -r -s -p 'Repeat Grafana admin password: ' GRAFANA_PASSWORD_CONFIRM
  echo
  [[ -n "$GRAFANA_PASSWORD" ]] || { echo 'ERROR: password must not be empty.' >&2; exit 9; }
  [[ "$GRAFANA_PASSWORD" == "$GRAFANA_PASSWORD_CONFIRM" ]] || {
    echo 'ERROR: passwords do not match.' >&2
    exit 10
  }
  umask 077
  {
    printf 'GF_SECURITY_ADMIN_USER=admin\n'
    printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$GRAFANA_PASSWORD"
    printf 'GF_USERS_ALLOW_SIGN_UP=false\n'
    printf 'GF_METRICS_ENABLED=true\n'
    printf 'GF_SERVER_HTTP_ADDR=%s\n' "$MGMT_IP"
    printf 'GF_SERVER_HTTP_PORT=3000\n'
  } > /etc/monitoring/grafana.env
  unset GRAFANA_PASSWORD GRAFANA_PASSWORD_CONFIRM
fi

cat > /etc/systemd/system/node-exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter container
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStartPre=-/usr/bin/podman rm -f node-exporter
ExecStart=/usr/bin/podman run --name node-exporter --rm --network host --pid host --read-only --security-opt label=disable -v /:/host:ro,rslave ${NODE_IMAGE} --path.rootfs=/host --web.listen-address=127.0.0.1:9100
ExecStop=/usr/bin/podman stop -t 20 node-exporter
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/alertmanager.service <<EOF
[Unit]
Description=Prometheus Alertmanager container
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStartPre=-/usr/bin/podman rm -f alertmanager
ExecStart=/usr/bin/podman run --name alertmanager --rm --network host --security-opt=no-new-privileges -v /etc/alertmanager:/etc/alertmanager:ro,Z -v /var/lib/alertmanager:/alertmanager:Z ${ALERT_IMAGE} --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/alertmanager --web.listen-address=127.0.0.1:9093
ExecStop=/usr/bin/podman stop -t 30 alertmanager
TimeoutStopSec=45

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus monitoring server container
RequiresMountsFor=/var/lib/prometheus
Wants=network-online.target alertmanager.service node-exporter.service
After=network-online.target alertmanager.service node-exporter.service

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStartPre=-/usr/bin/podman rm -f prometheus
ExecStart=/usr/bin/podman run --name prometheus --rm --network host --security-opt=no-new-privileges -v /etc/prometheus:/etc/prometheus:ro,Z -v /var/lib/prometheus:/prometheus:Z ${PROM_IMAGE} --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=7d --storage.tsdb.retention.size=20GB --web.enable-admin-api --web.listen-address=127.0.0.1:9090
ExecStop=/usr/bin/podman stop -t 30 prometheus
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/grafana.service <<EOF
[Unit]
Description=Grafana server container
Wants=network-online.target prometheus.service
After=network-online.target prometheus.service

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStartPre=-/usr/bin/podman rm -f grafana
ExecStart=/usr/bin/podman run --name grafana --rm --network host --security-opt=no-new-privileges --env-file /etc/monitoring/grafana.env -v /etc/grafana/provisioning:/etc/grafana/provisioning:ro,Z -v /var/lib/grafana:/var/lib/grafana:Z ${GRAFANA_IMAGE}
ExecStop=/usr/bin/podman stop -t 30 grafana
TimeoutStopSec=45

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node-exporter.service
systemctl enable --now alertmanager.service
systemctl enable --now prometheus.service
systemctl enable --now grafana.service

firewall-cmd --permanent --zone=nw-mgmt \
  --add-rich-rule='rule family="ipv4" source address="192.168.14.0/24" port port="3000" protocol="tcp" accept'
firewall-cmd --reload

echo '[Services]'
systemctl --no-pager --full status node-exporter.service alertmanager.service prometheus.service grafana.service || true
echo '[Listening ports]'
ss -lntp | grep -E ':(3000|9090|9093|9100)[[:space:]]'
echo '[Local health]'
curl -fsS http://127.0.0.1:9090/-/ready
echo
curl -fsS http://127.0.0.1:9093/-/ready
echo
curl -fsS http://127.0.0.1:9100/metrics >/dev/null
curl -fsS "http://${MGMT_IP}:3000/api/health"
echo
echo 'STANDALONE_MONITORING_BASE_READY'
