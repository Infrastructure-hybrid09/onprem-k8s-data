# 외부 Monitoring VM

중앙 Prometheus, Grafana, Alertmanager, Blackbox Exporter는 Kubernetes 외부의 Monitoring VM `192.168.14.73`에서 운영합니다.

| 구성요소 | 버전 | 역할 |
| --- | --- | --- |
| Prometheus | 3.13.1 | 메트릭 수집·TSDB 저장 |
| Grafana | 13.1.1 | 대시보드와 로그 조회 |
| Alertmanager | 0.33.1 | 경보 그룹화·Gmail 발송 |
| Node Exporter | 1.12.1 | Monitoring VM 자원 수집 |

Prometheus는 30GB 별도 데이터 디스크를 `/var/lib/prometheus`에 마운트하고, 보존 기간 7일·TSDB 최대 20GB로 운영합니다. Prometheus와 Alertmanager는 localhost에만 바인딩하고 Grafana만 관리망 `3000/tcp`로 제공합니다.

실제 설치·구성 스크립트는 [monitoring/external](../monitoring/external/)에 있습니다. 기존 Kubernetes 내부 Prometheus·Local PV·Longhorn 절차는 현재 최종 구성에 포함하지 않습니다.

