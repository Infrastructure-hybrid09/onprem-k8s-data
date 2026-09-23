# Loki와 Grafana Alloy

```text
Kubernetes Pod 로그
  → Grafana Alloy DaemonSet
  → Loki Gateway
  → MinIO의 Loki 전용 버킷
  → Grafana 조회
```

| 구성요소 | 버전 | 역할 |
| --- | --- | --- |
| Grafana Alloy | 1.19.0 | 각 노드의 Pod 로그 수집·라벨링 |
| Loki | 3.7.6 | 로그 인덱싱·조회·보존 |

Alloy는 Control Plane과 Worker에 DaemonSet으로 배포합니다. Namespace, Pod, Container, Node, App 라벨을 붙여 Loki로 전송합니다.

- Alloy 설정: [values-alloy.yaml](../configs/logging/values-alloy.yaml)
- Loki·MinIO 예제: [values-loki-minio.example.yaml](../configs/logging/values-loki-minio.example.yaml)

기존 `values-loki.yaml`의 `filesystem`·Pod 임시 저장소 구성은 초기 설계이므로 최종 예제에서 제외했습니다. MinIO의 실제 Access Key와 Secret Key는 배포용 Secret으로 관리합니다.

