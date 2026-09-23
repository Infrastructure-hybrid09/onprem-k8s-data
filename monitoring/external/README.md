# PC6 외부 Monitoring VM 전환 가이드

## 1. 목표

Main Kubernetes 클러스터 안에서 실행되던 중앙 모니터링을 PC6의 별도 VM으로
이전한다.

```text
PC6 monitoring VM
├─ Prometheus      메트릭 수집·TSDB 저장
├─ Grafana         대시보드
├─ Alertmanager    경보 처리
└─ Node Exporter   Monitoring VM 자체 상태

Main Kubernetes에 유지
├─ monitoring/node-exporter DaemonSet
├─ monitoring-kube-state-metrics
├─ Backend Actuator
├─ Alloy
└─ Loki            추후 저장소만 MinIO로 변경
```

Blackbox Exporter는 PC6 Monitoring VM에서 Main K8s Worker의 Internal NodePort를
통해 Frontend와 Backend 가용성을 점검한다. DMZ Service VIP 경로가 아니라
`192.168.34.41~43:30443`을 직접 점검하며, 설치와 Prometheus 등록은
`09_install_blackbox_exporter.sh`에서 수행한다.

## 2. 중요한 현재 상태

- Helm release: `monitoring`
- kube-prometheus-stack chart: `87.21.0`
- Prometheus 보존 기간: 7일
- 기존 Longhorn PVC: 15Gi
- 기존 TSDB 최대값: 12GB
- 새 VM 데이터 디스크: 30GB
- 새 VM TSDB 최대값: 20GB
- NFS 백업: 매일 01:30, `/backup/prometheus`
- NFS → MinIO: 매일 02:30
- 최신 확인 백업: `prometheus_20260904T013000_KST_6dc2ac0fab0b1cf1.tar.gz`

현재 `values-monitoring.yaml`의 `nodeExporter.enabled`는 `false`이다. Main K8s의
Node Exporter는 kube-prometheus-stack 내장 DaemonSet이 아니라 팀원이 별도로
설치한 `monitoring/node-exporter` DaemonSet이다. Helm release를 변경하더라도 이
별도 DaemonSet은 삭제하면 안 된다.

## 3. 담당자에게 받을 VM

| 항목 | 값 |
|---|---|
| Hostname | `monitoring` |
| vCPU / RAM | 4 vCPU / 8GB |
| OS 디스크 | 30GB |
| Prometheus 데이터 디스크 | 30GB, 미포맷 상태 |
| Management | `192.168.14.73/24`, GW·DNS `192.168.14.62` |
| Internal | `192.168.34.73/24`, 기본 게이트웨이 없음 |
| Data | `192.168.44.73/24`, 기본 게이트웨이 없음 |
| Grafana | `http://192.168.14.73:3000`, Management 대역만 허용 |

IP는 담당자가 중복 여부를 확인하고 확정한 값을 우선한다. 주소가 변경되면 이
폴더의 모든 `.73` 값도 함께 변경한다.

## 4. 전체 작업 순서

| 단계 | 실행 위치 | 변경 여부 | 내용 |
|---|---|---|---|
| 0 | DevOps VM | 읽기 전용 | 기존 버전·설정·수집기 확인 |
| 1 | monitoring VM | 읽기 전용 | 네트워크·디스크·NFS·대상 포트 확인 |
| 2 | monitoring VM | 변경 | 두 번째 디스크 XFS 구성 |
| 3 | monitoring VM | 변경 | 기존과 같은 버전의 Prometheus·Grafana·Alertmanager·Node Exporter 설치 |
| 4 | Main/DR K8s 담당 | 변경 | 외부 수집용 최소권한 CA·Token 준비 |
| 5 | monitoring VM | 변경 | `prometheus.yml`과 경보 규칙 적용 |
| 6 | monitoring VM | 변경 | 최신 NFS TSDB 백업 복구 |
| 7 | monitoring VM | 변경 | Grafana datasource·대시보드 provisioning |
| 8 | monitoring VM | 변경 | 01:30 NFS 백업 자동화 |
| 9 | 전체 | 시험 | Target·과거 데이터·대시보드·백업 검증 |
| 10 | DevOps VM | 변경 | K8s 중앙 Prometheus·Grafana·Alertmanager 비활성화 |
| 11 | DevOps VM | 파괴적 | Longhorn PVC와 Longhorn 제거 |
| 12 | monitoring VM | 변경 | Blackbox Exporter 설치 및 Main K8s 서비스 가용성 점검 |

단계 9가 끝날 때까지 기존 K8s 중앙 모니터링과 Longhorn을 삭제하지 않는다.

## 5. 단계 0: 기존 환경 정보 수집

실행 위치: DevOps VM

```bash
cd /home/devops/monitoring/external-monitoring-pc6
chmod 750 00_collect-current-state.sh
./00_collect-current-state.sh
```

이 스크립트는 Secret 내용이나 비밀번호를 출력하지 않는다. 다음 내용을 확정한다.

- 실제 Prometheus/Grafana/Alertmanager 이미지 버전
- 현재 Helm values
- 별도 Node Exporter DaemonSet 존재 여부
- kube-state-metrics Service 이름과 포트
- Backend Service 이름과 포트
- 기존 ServiceMonitor·PrometheusRule 목록

TSDB 복구 전에는 기존 Prometheus와 같은 버전을 새 VM에 설치하는 것을 기본으로
한다. 복구 성공 후 별도 작업으로 업그레이드한다.

## 6. 단계 1: PC6 VM 사전 점검

실행 위치: `monitoring`

```bash
chmod 750 01_pc6_preflight.sh
./01_pc6_preflight.sh
```

필수 조건:

- 기본 경로가 Management NIC 하나뿐임
- 30GB OS 디스크와 별도의 30GB 미포맷 디스크가 보임
- `192.168.34.100:6443`, `192.168.34.71:6443` 연결 가능
- NFS `192.168.44.61:2049` 연결 가능
- MinIO `192.168.44.72:9000` 연결 가능
- Grafana용 `3000/tcp`는 Management에서만 인바운드 허용

## 7. 단계 2: Prometheus 데이터 디스크 구성

`lsblk`로 두 번째 디스크 이름을 확인한다. 아래 예시의 `/dev/sdb`를 추측해서
사용하면 안 된다.

```bash
sudo dnf install -y parted xfsprogs util-linux
sudo ./02_prepare_prometheus_disk.sh /dev/sdb
```

스크립트는 다음 안전 조건을 확인한 뒤 `FORMAT-PROMETHEUS-DISK` 입력을 요구한다.

- 블록 장치가 실제로 존재함
- 현재 마운트되어 있지 않음
- 파티션이 존재하지 않음
- 기존 파일시스템 시그니처가 없음
- OS 루트 디스크가 아님

완료 목표:

```text
/dev/sdb1 → XFS → /var/lib/prometheus
```

이 단계에서는 마운트 지점을 `root:root`로 만든다. Prometheus 설치 후 실제 서비스
계정이 확정되면 `/var/lib/prometheus`의 소유권을 `prometheus:prometheus`로 바꾼다.

## 8. 단계 3: 프로그램 설치 원칙

설치 버전은 단계 0에서 확인한 기존 컨테이너 버전에 맞춘다. 다음 디렉터리 구조를
사용한다.

```text
/etc/prometheus/
├─ prometheus.yml
├─ rules/
├─ auth/main-k8s/
│  ├─ ca.crt
│  └─ token
└─ auth/dr-k3s/
   ├─ ca.crt
   └─ token

/var/lib/prometheus/       두 번째 30GB 디스크
/etc/alertmanager/
/var/lib/alertmanager/
/etc/grafana/provisioning/
/var/lib/grafana/dashboards/
```

Prometheus 실행 옵션:

```text
--config.file=/etc/prometheus/prometheus.yml
--storage.tsdb.path=/var/lib/prometheus
--storage.tsdb.retention.time=7d
--storage.tsdb.retention.size=20GB
--web.enable-admin-api
--web.listen-address=127.0.0.1:9090
```

`20GB`는 세 번째 디스크가 아니라 30GB 데이터 디스크 안에서 Prometheus가 사용할
최대 TSDB 크기다. 나머지 공간은 WAL·compaction·snapshot 작업과 파일시스템 여유로
남긴다.

Prometheus `9090`과 Alertmanager `9093`은 우선 localhost에만 바인딩한다.
Grafana만 Management 주소의 `3000/tcp`로 제공한다.

확인된 기존 이미지 버전은 다음과 같다.

```text
Prometheus     quay.io/prometheus/prometheus:v3.13.1-distroless
Grafana        docker.io/grafana/grafana:13.1.1
Alertmanager   quay.io/prometheus/alertmanager:v0.33.1
Node Exporter  quay.io/prometheus/node-exporter:v1.12.1
```

새 VM에서는 위 이미지를 rootful Podman 컨테이너로 실행하고 systemd가 관리한다.
Kubernetes 전용 config-reloader와 Grafana sidecar는 설치하지 않는다.

```bash
chmod 750 03_install_standalone_services.sh
sudo ./03_install_standalone_services.sh
```

스크립트는 Grafana 관리자 비밀번호를 두 번 입력받으며, 평문을 화면에 출력하지
않는다. 초기 단계에서는 Prometheus 자체, Monitoring VM Node Exporter, Grafana,
Alertmanager만 수집한다. Main/DR Kubernetes 및 나머지 VM 대상은 인증 파일을 받은
후 추가한다.

## 9. 단계 4: Kubernetes 인증정보

외부 Prometheus는 ServiceMonitor CRD를 직접 해석하지 않는다. Main K8s와 DR K3s
API Server의 Service Proxy를 사용해 kube-state-metrics와 Backend를 수집한다.

Kubernetes 담당자에게 다음 파일을 받는다.

```text
Main K8s
├─ ca.crt
└─ 최소권한 Bearer Token

DR K3s
├─ ca.crt
└─ dr-monitoring-reader Bearer Token
```

권한 범위:

- `/metrics` GET
- `monitoring` Namespace Service Proxy GET
- `application` Namespace Service Proxy GET
- 리소스 수정·삭제 권한 없음

만료되는 Token을 파일에 고정하면 다시 `401 Unauthorized`가 발생한다. 장기 토큰을
최소권한으로 발급하거나 갱신·재배포 절차를 함께 정해야 한다. Token은 Git이나
일반 YAML에 기록하지 않고 Monitoring VM에서 `0600`으로 저장한다.

## 10. 단계 5: 외부 Prometheus 수집 대상

현재 `values-monitoring.yaml`에서 다음 Job을 이전한다.

| Job | 대상 |
|---|---|
| `node-exporter-vm` | LB1/2, DevOps, DB1/2, NFS, Infra, MinIO, monitoring |
| `node-exporter-k8s-existing` | Main CP 3대, Worker 3대, DR K3s |
| `mariadb` | `192.168.44.51:9104`, `192.168.44.52:9104` |
| `main-kube-state-metrics` | Main API VIP의 Service Proxy |
| `main-backend` | Main API VIP의 Backend Service Proxy |
| `dr-k3s-supervisor` | DR K3s `/metrics` |
| `dr-kube-state-metrics` | DR API의 Service Proxy |
| `dr-backend` | DR API의 Backend Service Proxy |
| `prometheus` | PC6 Prometheus 자체 상태 |
| `grafana` | PC6 Grafana 자체 상태 |
| `alertmanager` | PC6 Alertmanager 자체 상태 |

Main K8s Service Proxy 후보 경로:

```text
https://192.168.34.100:6443/api/v1/namespaces/monitoring/services/monitoring-kube-state-metrics:8080/proxy/metrics
https://192.168.34.100:6443/api/v1/namespaces/application/services/neuroplan-backend:8080/proxy/actuator/prometheus
```

서비스 이름·포트와 API VIP 인증서 SAN은 단계 0 결과 및 Kubernetes 담당자 확인 후
확정한다.

Main/DR 인증 파일을 `/etc/prometheus/credentials`에 배치한 뒤 전체 정적 수집 설정을
적용한다.

```bash
cd /home/ansible/external-monitoring-pc6
chmod 750 04_apply_full_scrape_config.sh
sudo ./04_apply_full_scrape_config.sh
```

스크립트는 현재 설정을 타임스탬프가 붙은 파일로 백업하고 `promtool` 검증을 통과한
경우에만 새 설정을 적용한다. 재시작 또는 Ready 확인이 실패하면 기존 설정으로
자동 복구한다.

## 11. 단계 6: NFS 백업 복구

NFS 서버에서 최신 백업을 먼저 검증한다.

```bash
cd /backup/prometheus
BACKUP=prometheus_20260904T013000_KST_6dc2ac0fab0b1cf1.tar.gz
sudo sha256sum -c "${BACKUP}.sha256"
sudo gzip -t "$BACKUP"
sudo tar -tzf "$BACKUP" >/dev/null
```

세 명령이 모두 성공한 경우에만 새 VM의 비어 있는
`/var/lib/prometheus`에 복구한다. 복구 중에는 Prometheus를 중지한다.

주의:

- 이 백업은 Prometheus TSDB만 포함한다.
- 복구 지점은 2026-09-04 01:30이다.
- 그 이후 메트릭은 복구할 수 없다.
- 압축 파일 크기와 실제 TSDB 사용량은 같지 않다.

실제 압축 해제 명령은 새 VM에서 Prometheus 실행 UID/GID와 NFS 마운트 경로를
확인한 뒤 확정한다.

## 12. 단계 7: Grafana 대시보드 이전

현재 대시보드는 다음 폴더의 ConfigMap YAML 안에 JSON으로 저장돼 있다.

```text
/home/devops/monitoring/grafana-dashboards-v2/
```

일반 VM에서는 Kubernetes sidecar가 없으므로 다음 구조로 변환한다.

```text
ConfigMap data의 *.json
→ /var/lib/grafana/dashboards/*.json
→ /etc/grafana/provisioning/dashboards/infraready.yaml
```

Prometheus datasource:

```text
name: Prometheus
uid: prometheus
url: http://127.0.0.1:9090
```

현재 05 대시보드는 K8s Pod 형태의 Prometheus·Grafana·Alertmanager와 Longhorn을
조회한다. 외부 VM 전환 후에는 다음처럼 수정해야 한다.

- Prometheus: `up{job="prometheus"}`
- Grafana: `up{job="grafana"}`
- Alertmanager: `up{job="alertmanager"}`
- Longhorn 패널: 제거
- Monitoring VM CPU·RAM·디스크: Node Exporter 기반 패널 추가

## 13. 단계 8: 백업 자동화

PC6에서는 포트포워딩 없이 로컬 Admin API를 호출한다.

```text
POST http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot?skip_head=false
```

백업 정책:

```text
01:30  PC6 Prometheus snapshot → NFS /backup/prometheus
02:30  NFS /backup 전체 → MinIO nfs-backup/nfs-data
```

완성된 `.tar.gz`와 `.sha256`만 NFS에 기록한다. `.partial` 파일은 최종 파일로
인식하지 않는다. NFS 쓰기가 실패하면 로컬 staging에 남기고 다음 실행에서 다시
전송하도록 구성한다.

## 14. 단계 9: 전환 완료 기준

다음 항목을 모두 통과해야 기존 환경을 비활성화한다.

- Prometheus `/api/v1/targets`의 필수 Target이 모두 `UP`
- Main K8s 노드 6대와 DR K3s Node Exporter 수집
- Main/DR kube-state-metrics 수집
- Main/DR Backend Actuator 수집
- MariaDB 2대·NFS·MinIO VM 메트릭 수집
- Grafana 01~06 대시보드 데이터 출력
- 2026-09-04 이전 메트릭 조회
- 새 메트릭이 현재 시각으로 기록됨
- 수동 snapshot → NFS → SHA-256 검증 성공
- Main K8s의 Prometheus를 잠시 중지해도 PC6 수집 지속

## 15. 단계 10: kube-prometheus-stack 처리

전체 Helm release를 바로 삭제하지 않는다. 외부 모니터링 검증 후 다음 값만
비활성화한다.

```yaml
prometheus:
  enabled: false

grafana:
  enabled: false

alertmanager:
  enabled: false

prometheusOperator:
  enabled: true

kubeStateMetrics:
  enabled: true

# 현재 별도 monitoring/node-exporter DaemonSet을 사용하므로 계속 false
nodeExporter:
  enabled: false
```

Operator는 전환 기간에 유지한다. 외부 Prometheus가 필요한 수집·경보 설정을 모두
직접 관리하게 된 뒤 별도 정리 여부를 결정한다.

## 16. 단계 11: Longhorn 제거

아래 조건을 모두 만족한 뒤에만 실행한다.

- PC6 Prometheus가 정상 수집 중
- NFS 백업 복구 성공
- PC6에서 새 NFS snapshot 생성 성공
- Longhorn 사용 PVC가 Prometheus 하나뿐임
- K8s Prometheus가 Helm 설정으로 비활성화됨

삭제 순서:

```text
Prometheus Longhorn PVC
→ Longhorn Volume 소멸 확인
→ Longhorn Helm release 제거
→ Worker1·Worker3 /var/lib/longhorn 잔여 데이터 확인 후 정리
```

`/var/lib/longhorn` 또는 `/var/lib/containerd`를 수동으로 먼저 삭제하면 안 된다.

## 17. 롤백 기준

PC6 수집 또는 대시보드에 문제가 있으면 단계 10을 실행하지 않고 기존 K8s 설정을
유지한다. 단계 10 이후지만 Longhorn을 아직 삭제하지 않았다면 기존 Helm 값을 다시
적용하고 Prometheus를 재활성화할 수 있다. Longhorn PVC를 삭제한 뒤에는 NFS/MinIO
백업 복구만 가능하다.

## 18. Blackbox Exporter 서비스 가용성 점검

Monitoring VM의 Internal NIC에서 Main K8s Worker 3대의 NodePort `30443` 연결과
Frontend `/`, Backend `/api/health`의 HTTP 200 응답을 확인한 뒤 실행한다.

```bash
cd /home/ansible/external-monitoring-pc6
chmod 750 09_install_blackbox_exporter.sh
sudo ./09_install_blackbox_exporter.sh
```

다음 결과가 출력되면 설치와 Prometheus 등록이 완료된 것이다.

```text
BLACKBOX_MONITORING_READY
BLACKBOX_TARGETS=6
```

Blackbox Exporter는 `127.0.0.1:9115`에만 바인딩하므로 별도 인바운드 방화벽 개방은
필요하지 않다. 이 점검은 K8s 내부 서비스 가용성 검사이며 DMZ VIP와 HAProxy의
외부 사용자 전체 경로 검사는 포함하지 않는다.

6개 Probe가 모두 정상인 것을 확인한 다음 전용 경보와 Grafana 패널을 반영한다.

```bash
cd /home/ansible/external-monitoring-pc6
chmod 750 10_add_blackbox_alerts_dashboard.sh
sudo ./10_add_blackbox_alerts_dashboard.sh
```

추가되는 경보는 서비스 Probe 실패 1분 지속 시 Critical, 전체 Probe 응답시간이
2초를 5분 동안 초과할 때 Warning이다. Observability Platform 대시보드에는
Frontend 가용성, Backend 가용성, Probe 응답시간 패널이 추가된다.

## 19. Alertmanager Gmail 수신처

Google 계정에 2단계 인증을 활성화하고 Alertmanager 전용 16자리 앱 비밀번호를
발급한 후 실행한다. Google 계정의 일반 로그인 비밀번호를 입력하면 안 된다.

```bash
cd /home/ansible/external-monitoring-pc6
chmod 750 11_configure_alertmanager_gmail.sh
bash -n 11_configure_alertmanager_gmail.sh
sudo ./11_configure_alertmanager_gmail.sh
```

스크립트는 발신 Gmail 주소, 수신 주소, 앱 비밀번호를 대화형으로 입력받는다.
앱 비밀번호는 화면이나 명령 이력에 노출하지 않고
`/etc/alertmanager/secrets/gmail-app-password`에 `0640` 권한으로 저장한다.
설정 검증과 재시작 후 `GmailDeliveryTest` 시험 경보를 전송한다.

## 20. MariaDB 서비스 장애 경보

두 MariaDB Exporter에서 `mysql_up=1`이 수집되는 것을 확인한 뒤 다음을 실행한다.

```bash
cd /home/ansible/external-monitoring-pc6
chmod 750 12_add_mariadb_service_alert.sh
bash -n 12_add_mariadb_service_alert.sh
sudo ./12_add_mariadb_service_alert.sh
```

`mysql_up{job="mariadb"} == 0`이 1분간 지속되면 `MariaDBServiceDown` Critical
경보가 발생한다. Exporter 포트 자체가 끊긴 경우에는 기존 `TargetDown` 경보가
담당하며, 두 조건을 분리해 DB 프로세스 장애와 Exporter 수집 장애를 구분한다.

## 21. Alertmanager 이메일의 내부 링크 제거

Alertmanager 기본 HTML의 `monitoring:9093` 및 `monitoring:9090` 링크는 localhost
전용 구성에서 사용자 PC가 열 수 없다. 다음 스크립트는 기본 HTML을 사용자
템플릿으로 교체하고 `Grafana에서 확인` 버튼을 PC6 Grafana 대시보드로 연결한다.

```bash
cd /home/ansible/external-monitoring-pc6
chmod 750 13_customize_alertmanager_email.sh
bash -n 13_customize_alertmanager_email.sh
sudo ./13_customize_alertmanager_email.sh
```

기존 Gmail 주소와 앱 비밀번호 파일은 그대로 사용하며 비밀번호를 다시 입력하거나
설정 파일에 평문으로 기록하지 않는다.

## 22. Observability 대시보드 단순화와 한글 이메일

Worker별 Frontend·Backend·응답시간 패널은 장애 분석용 메트릭과 경보만 유지하고
Observability 대시보드에서는 제거한다. 이메일은 alertname과 job을 기준으로 한글
장애명, 대상 시스템, 원인 설명을 표시한다.

```bash
cd /home/ansible/external-monitoring-pc6
chmod 750 14_simplify_dashboard_korean_email.sh
bash -n 14_simplify_dashboard_korean_email.sh
sudo ./14_simplify_dashboard_korean_email.sh
```

Gmail 앱 비밀번호 파일은 수정하지 않는다. 이후 이메일에는 내부 전용 Alertmanager와
Prometheus 링크 대신 PC6 Grafana 버튼이 표시된다.
