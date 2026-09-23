# MinIO 2차 객체 저장소

MinIO는 별도 VM과 별도 XFS 데이터 디스크 `/srv/minio-data`에서 동작합니다.

| 항목 | 값 |
| --- | --- |
| S3 API | `https://192.168.44.72:9000` |
| Console | `https://192.168.14.72:9001` |
| 데이터 경로 | `/srv/minio-data` |
| NFS 백업 버킷 | `nfs-backup` |

- TLS 인증서 설치: [install-minio-tls.sh](../scripts/install-minio-tls.sh)
- 버킷·서비스 계정 구성: [configure-minio-buckets.sh](../scripts/configure-minio-buckets.sh)
- NFS 백업 정책: [nfs-backup-policy.json](../configs/minio/nfs-backup-policy.json)
- Loki 저장 정책: [loki-data-policy.json](../configs/minio/loki-data-policy.json)

백업 계정에는 목록 조회, 업로드, 다운로드 권한만 부여하고 객체 삭제 권한은 부여하지 않습니다. 따라서 NFS 원본을 실수로 삭제해도 MinIO 객체가 자동으로 삭제되지 않습니다.

Loki 서비스 계정은 Compactor의 보존 정책 수행을 위해 `loki-data` 버킷에 한해 객체 삭제 권한을 갖습니다. NFS 백업 계정과 Loki 계정을 분리하여 권한 범위를 섞지 않습니다.

MinIO 서버의 기본 설치 Ansible Role은 CI/CD 담당자가 수행했으므로 이 저장소에는 포함하지 않습니다. 여기에는 담당자가 설치 이후 수행한 TLS, 버킷, 계정·정책과 NFS 연계 구성만 정리했습니다.

PDF 원본에 포함돼 있던 Root 계정 및 Secret Key는 이 저장소에서 제거했습니다.
