#!/usr/bin/env bash
set -Eeuo pipefail

OLD_CONFIGMAP='infraready-overview-dashboard'

echo '새 대시보드 수 확인'
COUNT=$(kubectl -n monitoring get configmap \
  -l app.kubernetes.io/part-of=infraready-observability \
  -o name | wc -l)
echo "NEW_DASHBOARD_CONFIGMAPS=$COUNT"

if [[ "$COUNT" -ne 6 ]]; then
  echo 'ERROR: 새 대시보드 6개가 모두 확인되지 않아 기존 대시보드를 보존합니다.' >&2
  exit 1
fi

if ! kubectl -n monitoring get configmap "$OLD_CONFIGMAP" >/dev/null 2>&1; then
  echo '기존 통합 대시보드 ConfigMap은 이미 없습니다.'
  exit 0
fi

read -r -p 'Grafana에서 새 대시보드 6개를 확인했다면 REMOVE-OLD 입력: ' ANSWER
if [[ "$ANSWER" != 'REMOVE-OLD' ]]; then
  echo '취소했습니다. 기존 통합 대시보드를 보존합니다.'
  exit 0
fi

kubectl -n monitoring delete configmap "$OLD_CONFIGMAP"
echo 'OLD_DASHBOARD_REMOVED'
echo '원본 YAML은 /home/devops/monitoring/infraready-overview-dashboard.yaml에 남아 있어 다시 적용할 수 있습니다.'
