#!/usr/bin/env bash
set -Eeuo pipefail

ALERTMANAGER_IMAGE='quay.io/prometheus/alertmanager:v0.33.1'
ALERT_CONFIG='/etc/alertmanager/alertmanager.yml'
TEMPLATE_DIR='/etc/alertmanager/templates'
TEMPLATE_FILE="${TEMPLATE_DIR}/infraready-email.tmpl"
DASHBOARD='/var/lib/grafana/dashboards/observability-platform.json'
GRAFANA_URL='http://192.168.14.73:3000/d/infraready-observability/infraready-observability?orgId=1'
STAMP=$(date +%Y%m%d-%H%M%S)
ALERT_CONFIG_BACKUP="${ALERT_CONFIG}.before-korean-email-${STAMP}"
TEMPLATE_BACKUP="${TEMPLATE_FILE}.before-korean-${STAMP}"
DASHBOARD_BACKUP="${DASHBOARD}.before-simplify-${STAMP}"
DASHBOARD_TEMP=$(mktemp /tmp/observability-simplify.XXXXXX.json)
TEMPLATE_EXISTED=false

cleanup() {
  rm -f -- "$DASHBOARD_TEMP"
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

for required_file in \
  "$ALERT_CONFIG" \
  /etc/alertmanager/secrets/gmail-app-password \
  "$DASHBOARD"; do
  [[ -s "$required_file" ]] || {
    echo "ERROR: 필수 파일이 없거나 비어 있습니다: $required_file" >&2
    exit 3
  }
done

SENDER=$(
  sed -nE "s/^[[:space:]]*smtp_from:[[:space:]]*'([^']+)'/\1/p" "$ALERT_CONFIG" |
    head -n 1
)
RECIPIENT=$(
  sed -nE "s/^[[:space:]]*- to:[[:space:]]*'([^']+)'/\1/p" "$ALERT_CONFIG" |
    head -n 1
)
[[ "$SENDER" == *@*.* && "$RECIPIENT" == *@*.* ]] || {
  echo 'ERROR: Gmail 발신·수신 주소를 현재 설정에서 읽지 못했습니다.' >&2
  exit 4
}

echo '[1/7] 대시보드와 Alertmanager 설정을 백업합니다.'
cp -a -- "$DASHBOARD" "$DASHBOARD_BACKUP"
cp -a -- "$ALERT_CONFIG" "$ALERT_CONFIG_BACKUP"
install -d -o root -g root -m 0755 "$TEMPLATE_DIR"
if [[ -e "$TEMPLATE_FILE" ]]; then
  TEMPLATE_EXISTED=true
  cp -a -- "$TEMPLATE_FILE" "$TEMPLATE_BACKUP"
fi

echo '[2/7] Worker별 Blackbox 패널 3개를 대시보드에서 제거합니다.'
jq '
  .panels |= map(select(.id != 14 and .id != 15 and .id != 16)) |
  .version = ((.version // 0) + 1)
' "$DASHBOARD" > "$DASHBOARD_TEMP"
jq empty "$DASHBOARD_TEMP"

echo '[3/7] 한글 장애 설명용 이메일 템플릿을 작성합니다.'
cat > "$TEMPLATE_FILE" <<'EOF'
{{ define "infraready.status.ko" -}}
{{- if eq .Status "firing" -}}장애 발생{{- else -}}복구 완료{{- end -}}
{{- end }}

{{ define "infraready.common.alertname.ko" -}}
{{- if eq .CommonLabels.alertname "TargetDown" -}}모니터링 수집 대상 연결 실패
{{- else if eq .CommonLabels.alertname "HostRootDiskUsageWarning" -}}서버 루트 디스크 사용량 주의
{{- else if eq .CommonLabels.alertname "HostRootDiskUsageCritical" -}}서버 루트 디스크 용량 위험
{{- else if eq .CommonLabels.alertname "PrometheusDataDiskUsageWarning" -}}Prometheus 데이터 디스크 사용량 주의
{{- else if eq .CommonLabels.alertname "MainKubernetesNodeNotReady" -}}Main Kubernetes 노드 비정상
{{- else if eq .CommonLabels.alertname "DRK3sNodeNotReady" -}}DR K3s 노드 비정상
{{- else if eq .CommonLabels.alertname "MariaDBReplicationIOStopped" -}}MariaDB 복제 IO 중단
{{- else if eq .CommonLabels.alertname "MariaDBReplicationSQLStopped" -}}MariaDB 복제 SQL 중단
{{- else if eq .CommonLabels.alertname "MariaDBReplicationLagWarning" -}}MariaDB 복제 지연 주의
{{- else if eq .CommonLabels.alertname "MariaDBReplicationLagCritical" -}}MariaDB 복제 지연 위험
{{- else if eq .CommonLabels.alertname "MariaDBServiceDown" -}}MariaDB 서비스 접속 실패
{{- else if eq .CommonLabels.alertname "NeuroplanServiceProbeFailed" -}}NeuroPlan 내부 서비스 응답 실패
{{- else if eq .CommonLabels.alertname "NeuroplanServiceSlowResponse" -}}NeuroPlan 내부 서비스 응답 지연
{{- else -}}{{ .CommonLabels.alertname }}
{{- end -}}
{{- end }}

{{ define "infraready.alertname.ko" -}}
{{- if eq .Labels.alertname "TargetDown" -}}모니터링 수집 대상 연결 실패
{{- else if eq .Labels.alertname "HostRootDiskUsageWarning" -}}서버 루트 디스크 사용량 주의
{{- else if eq .Labels.alertname "HostRootDiskUsageCritical" -}}서버 루트 디스크 용량 위험
{{- else if eq .Labels.alertname "PrometheusDataDiskUsageWarning" -}}Prometheus 데이터 디스크 사용량 주의
{{- else if eq .Labels.alertname "MainKubernetesNodeNotReady" -}}Main Kubernetes 노드 비정상
{{- else if eq .Labels.alertname "DRK3sNodeNotReady" -}}DR K3s 노드 비정상
{{- else if eq .Labels.alertname "MariaDBReplicationIOStopped" -}}MariaDB 복제 IO 중단
{{- else if eq .Labels.alertname "MariaDBReplicationSQLStopped" -}}MariaDB 복제 SQL 중단
{{- else if eq .Labels.alertname "MariaDBReplicationLagWarning" -}}MariaDB 복제 지연 주의
{{- else if eq .Labels.alertname "MariaDBReplicationLagCritical" -}}MariaDB 복제 지연 위험
{{- else if eq .Labels.alertname "MariaDBServiceDown" -}}MariaDB 서비스 접속 실패
{{- else if eq .Labels.alertname "NeuroplanServiceProbeFailed" -}}NeuroPlan 내부 서비스 응답 실패
{{- else if eq .Labels.alertname "NeuroplanServiceSlowResponse" -}}NeuroPlan 내부 서비스 응답 지연
{{- else -}}{{ .Labels.alertname }}
{{- end -}}
{{- end }}

{{ define "infraready.job.ko" -}}
{{- if eq .Labels.job "prometheus" -}}PC6 Prometheus
{{- else if eq .Labels.job "grafana" -}}PC6 Grafana
{{- else if eq .Labels.job "alertmanager" -}}PC6 Alertmanager
{{- else if eq .Labels.job "monitoring-node" -}}PC6 Monitoring VM
{{- else if eq .Labels.job "node-exporter-vm" -}}일반 인프라 VM
{{- else if eq .Labels.job "node-exporter-k8s-existing" -}}Kubernetes 또는 DR 노드
{{- else if eq .Labels.job "apiserver" -}}Main Kubernetes API Server
{{- else if eq .Labels.job "main-kube-state-metrics" -}}Main Kubernetes 오브젝트 상태 수집기
{{- else if eq .Labels.job "dr-kube-state-metrics" -}}DR K3s 오브젝트 상태 수집기
{{- else if eq .Labels.job "main-backend" -}}Main Backend
{{- else if eq .Labels.job "dr-backend" -}}DR Backend
{{- else if eq .Labels.job "dr-k3s-supervisor" -}}DR K3s Supervisor
{{- else if eq .Labels.job "mariadb" -}}MariaDB
{{- else if eq .Labels.job "loki" -}}Loki 로그 시스템
{{- else if eq .Labels.job "blackbox-neuroplan" -}}NeuroPlan 내부 HTTP 점검
{{- else -}}{{ .Labels.job }}
{{- end -}}
{{- end }}

{{ define "infraready.cause.ko" -}}
{{- if eq .Labels.alertname "TargetDown" -}}Prometheus가 대상의 메트릭 주소에 연결하거나 응답을 읽지 못하고 있습니다. 대상 서비스, Exporter, 네트워크 경로를 확인해야 합니다.
{{- else if eq .Labels.alertname "HostRootDiskUsageWarning" -}}대상 서버의 루트 디스크 사용률이 80%를 지속적으로 초과했습니다. 로그, 컨테이너 이미지 및 임시 파일 증가를 확인해야 합니다.
{{- else if eq .Labels.alertname "HostRootDiskUsageCritical" -}}대상 서버의 루트 디스크 사용률이 90%를 초과해 서비스 쓰기 실패 위험이 있습니다. 즉시 불필요한 파일을 확인하고 공간을 확보해야 합니다.
{{- else if eq .Labels.alertname "PrometheusDataDiskUsageWarning" -}}PC6 Prometheus 전용 데이터 디스크 사용률이 75%를 초과했습니다. TSDB 보존량과 백업 파일, 비정상적인 시계열 증가를 확인해야 합니다.
{{- else if eq .Labels.alertname "MainKubernetesNodeNotReady" -}}Main Kubernetes 노드가 Ready 상태가 아닙니다. 해당 노드의 kubelet, 컨테이너 런타임, 네트워크와 자원을 확인해야 합니다.
{{- else if eq .Labels.alertname "DRK3sNodeNotReady" -}}DR K3s 노드가 Ready 상태가 아닙니다. K3s 서비스와 노드 자원 및 네트워크를 확인해야 합니다.
{{- else if eq .Labels.alertname "MariaDBReplicationIOStopped" -}}Replica가 Primary의 binlog를 받아오는 IO Thread를 실행하지 못하고 있습니다. 네트워크, 복제 계정과 Last_IO_Error를 확인해야 합니다.
{{- else if eq .Labels.alertname "MariaDBReplicationSQLStopped" -}}Replica가 relay log를 적용하는 SQL Thread를 실행하지 못하고 있습니다. SHOW SLAVE STATUS의 Last_SQL_Error를 확인해야 합니다.
{{- else if eq .Labels.alertname "MariaDBReplicationLagWarning" -}}MariaDB 복제가 Primary보다 10초 이상 지연되고 있습니다. Replica 부하와 디스크 IO 및 장기 실행 쿼리를 확인해야 합니다.
{{- else if eq .Labels.alertname "MariaDBReplicationLagCritical" -}}MariaDB 복제가 Primary보다 30초 이상 지연되어 데이터 최신성이 크게 떨어진 상태입니다. 복제 상태를 즉시 확인해야 합니다.
{{- else if eq .Labels.alertname "MariaDBServiceDown" -}}MariaDB Exporter는 실행 중이지만 대상 DB에 접속하지 못하고 있습니다. 해당 MariaDB 서비스 상태와 포트, 로그를 확인해야 합니다.
{{- else if eq .Labels.alertname "NeuroplanServiceProbeFailed" -}}Monitoring VM에서 Worker NodePort를 통한 Frontend 또는 Backend HTTP 200 응답을 받지 못했습니다. 대상 Worker, Service, Pod와 NodePort 경로를 확인해야 합니다.
{{- else if eq .Labels.alertname "NeuroplanServiceSlowResponse" -}}Monitoring VM의 내부 HTTP 점검 응답시간이 2초를 지속적으로 초과했습니다. 애플리케이션 부하, Pod 자원과 내부 네트워크를 확인해야 합니다.
{{- else -}}{{ .Annotations.description }}
{{- end -}}
{{- end }}

{{ define "infraready.email.html" }}
<!doctype html>
<html lang="ko">
  <body style="font-family:Arial,sans-serif;color:#222;line-height:1.55">
    <h2 style="margin-bottom:8px">[InfraReady] {{ template "infraready.status.ko" . }} - {{ template "infraready.common.alertname.ko" . }}</h2>
    <p style="margin-top:0">심각도: <strong>{{ .CommonLabels.severity }}</strong></p>
    {{ range .Alerts }}
    <div style="border:1px solid #ddd;border-radius:6px;padding:14px;margin:12px 0">
      <div><strong>상태:</strong> {{ template "infraready.status.ko" . }}</div>
      <div><strong>장애 종류:</strong> {{ template "infraready.alertname.ko" . }}</div>
      <div><strong>대상 시스템:</strong> {{ template "infraready.job.ko" . }}</div>
      <div><strong>대상 주소:</strong> {{ .Labels.instance }}</div>
      <div style="margin-top:10px"><strong>한글 설명:</strong><br>{{ template "infraready.cause.ko" . }}</div>
      <div style="margin-top:10px"><strong>수집된 요약:</strong> {{ .Annotations.summary }}</div>
    </div>
    {{ end }}
    <p style="margin-top:20px">
      <a href="http://192.168.14.73:3000/d/infraready-observability/infraready-observability?orgId=1"
         style="display:inline-block;background:#3871dc;color:#fff;text-decoration:none;padding:10px 16px;border-radius:4px">
        Grafana에서 확인
      </a>
    </p>
    <p style="color:#666;font-size:12px">PC6 Monitoring VM의 Alertmanager에서 발송한 알림입니다.</p>
  </body>
</html>
{{ end }}
EOF
chown root:root "$TEMPLATE_FILE"
chmod 0644 "$TEMPLATE_FILE"

echo '[4/7] Alertmanager에 한글 제목과 HTML 템플릿을 연결합니다.'
cat > "$ALERT_CONFIG" <<EOF
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
          Subject: '[InfraReady] {{ template "infraready.status.ko" . }} - {{ template "infraready.common.alertname.ko" . }}'
        html: '{{ template "infraready.email.html" . }}'
        text: |-
          상태: {{ template "infraready.status.ko" . }}
          장애 종류: {{ template "infraready.common.alertname.ko" . }}
          심각도: {{ .CommonLabels.severity }}
          {{ range .Alerts }}
          대상 시스템: {{ template "infraready.job.ko" . }}
          대상 주소: {{ .Labels.instance }}
          설명: {{ template "infraready.cause.ko" . }}
          {{ end }}
          Grafana: ${GRAFANA_URL}
EOF
chown root:root "$ALERT_CONFIG"
chmod 0644 "$ALERT_CONFIG"

echo '[5/7] JSON과 Alertmanager 설정·템플릿을 검증합니다.'
if ! podman run \
  --rm \
  --entrypoint=/bin/amtool \
  -v /etc/alertmanager:/etc/alertmanager:ro,Z \
  "$ALERTMANAGER_IMAGE" \
  check-config \
  /etc/alertmanager/alertmanager.yml; then
  cp -a -- "$ALERT_CONFIG_BACKUP" "$ALERT_CONFIG"
  if $TEMPLATE_EXISTED; then
    cp -a -- "$TEMPLATE_BACKUP" "$TEMPLATE_FILE"
  else
    rm -f -- "$TEMPLATE_FILE"
  fi
  echo 'ERROR: Alertmanager 설정 검증 실패. 기존 상태로 복구했습니다.' >&2
  exit 5
fi

install -o 472 -g 472 -m 0640 "$DASHBOARD_TEMP" "$DASHBOARD"
restorecon -F "$DASHBOARD" 2>/dev/null || true

echo '[6/7] Alertmanager와 Grafana를 재시작합니다.'
if ! systemctl restart alertmanager.service; then
  cp -a -- "$ALERT_CONFIG_BACKUP" "$ALERT_CONFIG"
  if $TEMPLATE_EXISTED; then
    cp -a -- "$TEMPLATE_BACKUP" "$TEMPLATE_FILE"
  else
    rm -f -- "$TEMPLATE_FILE"
  fi
  systemctl restart alertmanager.service || true
  echo 'ERROR: Alertmanager 재시작 실패. 기존 상태로 복구했습니다.' >&2
  exit 6
fi

if ! systemctl restart grafana.service; then
  cp -a -- "$DASHBOARD_BACKUP" "$DASHBOARD"
  systemctl restart grafana.service || true
  echo 'ERROR: Grafana 재시작 실패. 대시보드를 복구했습니다.' >&2
  exit 7
fi

for _ in $(seq 1 30); do
  alert_ready=false
  grafana_ready=false
  curl -fsS http://127.0.0.1:9093/-/ready >/dev/null 2>&1 && alert_ready=true
  curl -fsS http://192.168.14.73:3000/api/health >/dev/null 2>&1 && grafana_ready=true
  if $alert_ready && $grafana_ready; then
    break
  fi
  sleep 1
done

curl -fsS http://127.0.0.1:9093/-/ready >/dev/null
curl -fsS http://192.168.14.73:3000/api/health >/dev/null

echo '[7/7] 최종 반영 결과를 확인합니다.'
remaining_blackbox_panels=$(
  jq '[.panels[] | select(.id == 14 or .id == 15 or .id == 16)] | length' "$DASHBOARD"
)
[[ "$remaining_blackbox_panels" == '0' ]] || {
  echo "ERROR: 제거되지 않은 Blackbox 패널 수: $remaining_blackbox_panels" >&2
  exit 8
}

grep -q 'Grafana에서 확인' "$TEMPLATE_FILE"
grep -q '한글 설명' "$TEMPLATE_FILE"

echo 'OBSERVABILITY_DASHBOARD_SIMPLIFIED'
echo 'KOREAN_ALERT_EMAIL_TEMPLATE_READY'
echo "GRAFANA_URL=$GRAFANA_URL"
echo "DASHBOARD_BACKUP=$DASHBOARD_BACKUP"
echo "ALERT_CONFIG_BACKUP=$ALERT_CONFIG_BACKUP"
