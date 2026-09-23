# Exporter와 Prometheus 수집

```text
Node Exporter ─────┐
MariaDB Exporter ──┼→ Prometheus → Grafana
Blackbox Exporter ─┘
```

| 수집기 | 대상 |
| --- | --- |
| Node Exporter | VM, Main K8s 노드, DR K3s 노드 |
| MariaDB Exporter | 연결 수, 요청량, 복제 Thread, 복제 지연 |
| Blackbox Exporter | Frontend·Backend HTTP/HTTPS 가용성 |
| kube-state-metrics | Kubernetes 오브젝트 상태 |
| Backend Actuator | NeuroPlan 애플리케이션 메트릭 |

MariaDB Exporter 설치 스크립트는 [install-mysqld-exporter.sh](../scripts/install-mysqld-exporter.sh)에 있습니다. 전체 Prometheus 수집 설정은 [04_apply_full_scrape_config.sh](../monitoring/external/04_apply_full_scrape_config.sh)에서 생성합니다.

Kubernetes API Token과 CA 파일은 저장소에 포함하지 않습니다.

