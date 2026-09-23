#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE=monitoring
RELEASE=monitoring

command -v kubectl >/dev/null
command -v helm >/dev/null

echo '[1/9] Kubernetes nodes'
kubectl get nodes -o wide

echo '[2/9] Helm release'
helm -n "$NAMESPACE" list

echo '[3/9] Central monitoring images'
kubectl -n "$NAMESPACE" get pod \
  -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{range .items[*].spec.containers[*]}{.name}{" = "}{.image}{"\n"}{end}' \
  2>/dev/null || true
kubectl -n "$NAMESPACE" get deployment monitoring-grafana \
  -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{" = "}{.image}{"\n"}{end}' \
  2>/dev/null || true
kubectl -n "$NAMESPACE" get pod \
  -l app.kubernetes.io/name=alertmanager \
  -o jsonpath='{range .items[*].spec.containers[*]}{.name}{" = "}{.image}{"\n"}{end}' \
  2>/dev/null || true

echo '[4/9] Monitoring workloads'
kubectl -n "$NAMESPACE" get deployment,statefulset,daemonset -o wide

echo '[5/9] Monitoring services'
kubectl -n "$NAMESPACE" get service -o wide

echo '[6/9] Backend service'
kubectl -n application get service neuroplan-backend -o wide
kubectl -n application get service neuroplan-backend \
  -o jsonpath='{range .spec.ports[*]}name={.name} port={.port} targetPort={.targetPort}{"\n"}{end}'

echo '[7/9] Monitoring CR inventory'
kubectl get servicemonitor,podmonitor,prometheusrule -A

echo '[8/9] Storage inventory'
kubectl get pvc -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName,VOLUME:.spec.volumeName,STATUS:.status.phase'
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns='VOLUME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,REPLICAS:.spec.numberOfReplicas' \
  2>/dev/null || true

echo '[9/9] Helm values (secret data is not printed)'
helm -n "$NAMESPACE" get values "$RELEASE" -a

echo 'CURRENT_STATE_COLLECTION_OK'

