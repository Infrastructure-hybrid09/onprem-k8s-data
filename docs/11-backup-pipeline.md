# 백업 흐름과 일정

```text
MariaDB Logical Dump ─┐
etcd Snapshot ────────┼→ NFS 1차 저장 → MinIO 2차 객체 사본
Prometheus Snapshot ──┘
```

| 대상 | 방식 | 실행 시각 | NFS 보존 |
| --- | --- | --- | --- |
| Prometheus | TSDB Snapshot | 매일 01:30 | 14일 |
| MariaDB | Logical Dump | 매일 02:00 | 30일 |
| etcd | Snapshot | 매일 02:00 계열 | 운영 설정 확인 |
| NFS → MinIO | 객체 복사 | 매일 02:30 계열 | MinIO Lifecycle 적용 |

MariaDB 백업 스크립트는 `@@read_only`를 확인해 현재 쓰기 가능한 Primary에서만 실행됩니다. Prometheus 백업은 `.tar.gz`와 SHA-256 체크섬을 함께 생성합니다.

NFS → MinIO 작업에서는 `mc mirror --remove`를 사용하지 않습니다. NFS에서 삭제된 파일이 MinIO에서도 함께 삭제되는 것을 방지하기 위함입니다.

실행 코드는 다음 파일에 있습니다.

- [MariaDB 논리 백업](../scripts/db-backup.sh)
- [NFS → MinIO 2차 사본 생성](../scripts/nfs-to-minio-sync.sh)
- [MariaDB Cron 예제](../configs/cron/infraready-db-backup)
- [MinIO 복사 Cron 예제](../configs/cron/infraready-nfs-to-minio)
- [Prometheus Snapshot](../monitoring/external/prometheus-snapshot-to-nfs.sh)
