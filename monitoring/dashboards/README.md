# InfraReady Grafana 대시보드 v2

## 구성 원칙

멘토링 결과에 맞춰 **인프라 관점**과 **서비스 관점**을 분리했다.

| 번호 | 대시보드 | 포함 내용 |
|---|---|---|
| 01 | InfraReady Overview | 전체 Target, Main K8s, DR K3s, DB, 경보, 전체 서버 자원 |
| 02 | Infrastructure - Data Platform | MariaDB 2대, MaxScale VM, NFS VM, MinIO VM, DB 연결·QPS·복제 지연 |
| 03 | Infrastructure - Main Kubernetes | Main K8s 노드·Pod·Deployment·Longhorn 및 노드 자원 |
| 04 | Infrastructure - DR K3s | PC6 K3s, kube-state-metrics, Backend, Node Exporter 상태 |
| 05 | Infrastructure - Observability Platform | Prometheus, Grafana, Alertmanager, Loki, Alloy 운영 상태 |
| 06 | Service - NeuroPlan | Main/DR Frontend·Backend 가용성, 요청률, 5xx, JVM 메모리 |

MaxScale은 DB 요청의 진입점이므로 Data Platform에 포함했다. Loki 로그 본문은 상시 대시보드에 표시하지 않고 장애 분석 시 `Explore > Loki`에서 조회한다.

`09_neuroplan-backend-servicemonitor.yaml`은 Main Backend의 `/actuator/prometheus`를 30초마다 수집한다. 이미 확인한 Service의 `http` 포트와 `app.kubernetes.io/name=neuroplan-backend` 라벨을 사용한다.

## 저장 방식

각 대시보드는 `grafana_dashboard: "1"` 라벨이 붙은 Kubernetes ConfigMap이다. Grafana Pod가 다른 Worker로 이동하거나 재생성되어도 ConfigMap을 Grafana sidecar가 다시 읽으므로 대시보드는 유지된다.

Grafana 화면에서 직접 수정한 내용은 원본이 아니다. 변경할 때는 이 폴더의 YAML을 수정하고 다시 적용한다. Grafana 사용자 계정·사용자별 환경설정의 영속화는 대시보드 ConfigMap과 별개의 문제다.

## 1. Windows에서 DevOps VM으로 전송

실행 위치: Windows PowerShell

```powershell
cd "C:\Users\soldesk\Documents\ChatGPT\1차 팀프로젝트\monitoring\grafana-dashboards-v2"
Set-ExecutionPolicy -Scope Process Bypass -Force
.\00_copy-to-devops.ps1
```

## 2. DevOps VM에서 적용

실행 위치: DevOps VM `devops@192.168.14.21`

```bash
cd /home/devops/monitoring/grafana-dashboards-v2
chmod 750 07_apply-dashboards.sh 08_remove-old-dashboard.sh
./07_apply-dashboards.sh
```

Grafana sidecar 반영까지 10~60초 기다린 뒤 다음 경로에서 확인한다.

```text
https://grafana.nplan.local
→ 왼쪽 메뉴 Dashboards
→ Browse
```

## 3. PC6 수집 Target 확인

다음 값이 모두 `1`이어야 DR 대시보드에 값이 표시된다.

```bash
PROM_POD=$(kubectl -n monitoring get pod \
  -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n monitoring exec "$PROM_POD" -c prometheus -- \
  promtool query instant http://127.0.0.1:9090 \
  'up{job=~"dr-k3s-supervisor|dr-kube-state-metrics|dr-backend"}'
```

`promtool`이 컨테이너에 없으면 Grafana `Explore > Prometheus`에서 같은 PromQL을 실행한다.

## 4. 기존 통합 대시보드 정리

새 대시보드 6개가 정상 표시되는 것을 확인한 뒤에만 실행한다.

```bash
cd /home/devops/monitoring/grafana-dashboards-v2
./08_remove-old-dashboard.sh
```

확인 문구로 `REMOVE-OLD`를 입력해야 기존 `infraready-overview-dashboard` ConfigMap이 삭제된다. 원본 YAML은 삭제하지 않는다.

## 값이 비어 있을 때

- Main Backend 패널: 이번 묶음의 ServiceMonitor 적용 후 첫 수집까지 약 30~60초 비어 있을 수 있다.
- MinIO: 현재 Node Exporter 기반 VM 자원만 표시한다. MinIO 자체 Metrics 인증 연동 후 용량·요청·오류 패널을 추가한다.
- MaxScale: 현재 Node Exporter 기반 VM 자원만 표시한다. Master/Slave 역할과 Failover 이력은 MaxScale 전용 메트릭 수집이 추가되어야 표시할 수 있다.
- Loki 로그 본문: `Explore > Loki`에서 조회한다.

## 전체 제거 및 재적용

새 대시보드만 제거:

```bash
kubectl delete -k /home/devops/monitoring/grafana-dashboards-v2
```

재적용:

```bash
kubectl apply -k /home/devops/monitoring/grafana-dashboards-v2
```
