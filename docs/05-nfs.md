# NFS 1차 백업 저장소

NFS `192.168.44.61:2049`는 MariaDB, etcd, Prometheus 백업 파일의 1차 저장소입니다.

```text
/backup/
├─ mariadb/
├─ etcd/
├─ prometheus/
└─ config/
```

Export 예제는 [exports.example](../configs/nfs/exports.example)에 있습니다. DB 서버는 `/backup/mariadb`를 `/mnt/db-backup`에 NFSv4로 마운트합니다.

서버 구성 코드는 [setup-nfs-backup-server.sh](../scripts/setup-nfs-backup-server.sh)에 있습니다.

```fstab
192.168.44.61:/backup/mariadb /mnt/db-backup nfs4 defaults,_netdev,nofail,x-systemd.automount 0 0
```

NFS는 백업 결과를 파일 단위로 확인하고 복원 작업에 바로 사용할 수 있는 공용 저장 경로로 사용합니다. MinIO는 NFS를 대체하지 않고 2차 객체 사본을 보관합니다.
