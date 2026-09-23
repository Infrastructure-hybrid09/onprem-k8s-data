# InfraReady Data, Backup and Observability

NeuroPlan 온프레미스 환경에서 실제로 구축한 MariaDB HA, MaxScale, NFS·MinIO 백업, 외부 모니터링 및 Loki·Alloy 로그 수집 구성을 재현 가능한 코드와 문서로 정리한 저장소입니다. 최종 프로젝트 기준정보와 실제 작업 스크립트·채팅 기록을 우선했으며, 초기 PDF의 구버전 설정은 현재 구성에 맞게 갱신했습니다.

## 최종 구성

| 영역 | 구성 |
| --- | --- |
| Database | MariaDB 11.8, GTID Primary/Replica |
| DB routing | MaxScale 25.01, `readwritesplit`, 자동 Failover·Rejoin |
| Schema | `infraready` 23개 테이블 |
| 1차 백업 | NFS `192.168.44.61` |
| 2차 사본 | MinIO `192.168.44.72:9000` |
| Metrics | 외부 Monitoring VM의 Prometheus 3.13.1 |
| Dashboard | Grafana 13.1.1 |
| Alert | Alertmanager 0.33.1, Gmail 알림 |
| Logs | Grafana Alloy 1.19.0 → Loki 3.7.6 → MinIO |

## 문서

1. [MariaDB GTID 복제 구성](docs/01-mariadb-gtid-replication.md)
2. [MariaDB 계정과 권한](docs/02-mariadb-users.md)
3. [데이터베이스 스키마](docs/03-database-schema.md)
4. [MaxScale 구성](docs/04-maxscale.md)
5. [NFS 백업 저장소](docs/05-nfs.md)
6. [MinIO 객체 저장소](docs/06-minio.md)
7. [외부 모니터링 VM](docs/07-monitoring-vm.md)
8. [Exporter와 Prometheus 수집](docs/08-prometheus-exporters.md)
9. [Grafana와 Alertmanager](docs/09-grafana-alertmanager.md)
10. [Loki와 Grafana Alloy](docs/10-loki-alloy.md)
11. [백업 흐름과 일정](docs/11-backup-pipeline.md)

## 주요 코드

```text
configs/
├─ mariadb/
├─ maxscale/
├─ nfs/
├─ minio/
└─ logging/

sql/
├─ 01_infraready_schema.sql
├─ 02_seed_certification_subjects.sql
└─ 03_create_service_accounts.sql

monitoring/
├─ external/
└─ dashboards/

scripts/
├─ setup-nfs-backup-server.sh
├─ db-backup.sh
├─ nfs-to-minio-sync.sh
└─ install-mysqld-exporter.sh
```

## 권장 적용 순서

1. `configs/mariadb`의 Primary·Replica 설정을 적용하고 GTID 복제를 구성합니다.
2. `sql/01_infraready_schema.sql`로 23개 테이블을 생성하고 필요한 서비스 계정을 구성합니다.
3. `configs/maxscale/maxscale.cnf.example`을 기준으로 MaxScale 단일 접속 경로와 자동 Failover·Rejoin을 구성합니다.
4. `scripts/setup-nfs-backup-server.sh`로 NFS를 준비하고 MinIO의 TLS·버킷·권한을 구성합니다.
5. `scripts/db-backup.sh`와 `scripts/nfs-to-minio-sync.sh`를 Cron에 등록합니다.
6. `monitoring/external`의 번호 순서대로 외부 Monitoring VM을 구성합니다.
7. `configs/logging`으로 Alloy → Loki → MinIO 로그 흐름을 적용합니다.

`monitoring/external/README.md`는 Kubernetes 내부 모니터링에서 외부 VM으로 이전한 실제 작업 기록입니다. Longhorn 관련 내용은 현재 구성이 아니라 이전 과정의 출발 상태와 제거 절차를 설명합니다.

## 담당 범위와 파일 출처

이 저장소에는 DB·스토리지·모니터링 담당자가 직접 수행한 결과물과 해당 작업 기록을 GitHub용 코드로 재구성한 파일만 포함합니다. CI/CD 담당자가 수행한 MinIO Ansible Role과 실제 구축에 실행하지 않은 MaxScale 재구축용 Playbook은 포함하지 않습니다.

## 보안 원칙

- PDF 원본에 있던 평문 비밀번호는 포함하지 않았습니다.
- `<..._PASSWORD>`와 `<..._ACCESS_KEY>`는 배포 전에 Secret 값으로 교체합니다.
- 토큰, Gmail 앱 비밀번호, MinIO Secret Key, TLS 개인키는 Git에 커밋하지 않습니다.
- NFS에서 MinIO로 복사할 때 `mc mirror --remove`를 사용하지 않아 NFS의 실수 삭제가 MinIO에 전파되지 않게 합니다.

## 용어

설명에서는 Primary/Replica를 사용합니다. `maxctrl` 출력과 MariaDB의 기존 명령에 나타나는 Master/Slave는 제품 출력 그대로 표기합니다.
