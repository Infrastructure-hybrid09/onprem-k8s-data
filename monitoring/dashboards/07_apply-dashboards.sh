#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

echo '[1/4] Kubernetes 연결 확인'
kubectl cluster-info >/dev/null

echo '[2/4] YAML 사전 검증'
kubectl apply --dry-run=client -k "$SCRIPT_DIR" >/dev/null

echo '[3/4] 대시보드 ConfigMap 적용'
kubectl apply -k "$SCRIPT_DIR"

echo '[4/4] 적용 결과 확인'
kubectl -n monitoring get configmap \
  -l app.kubernetes.io/part-of=infraready-observability \
  -o custom-columns='NAME:.metadata.name,DASHBOARD:.metadata.labels.grafana_dashboard'

cat <<'EOF'

DASHBOARD_APPLY_OK
Grafana sidecar가 ConfigMap을 읽는 데 약 10~60초가 걸릴 수 있습니다.
Grafana > Dashboards에서 01~06으로 시작하는 대시보드를 확인하세요.
EOF
