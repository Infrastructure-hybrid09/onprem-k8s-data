# MariaDB GTID 복제 구성

## 구성

| 서버 | 초기 역할 | 데이터 주소 | server_id |
| --- | --- | --- | ---: |
| `db-primary` | Primary | `192.168.44.51:3306` | `1` |
| `db-replica` | Replica | `192.168.44.52:3306` | `2` |

두 서버는 동일한 `gtid_domain_id=1`을 사용하고, 각 서버에는 서로 다른 `server_id`를 부여합니다. Binary Log는 `ROW` 형식으로 기록합니다.

설정 예제:

- [Primary 설정](../configs/mariadb/60-infraready-primary.cnf)
- [Replica 설정](../configs/mariadb/60-infraready-replica.cnf)

Replica 연결의 핵심은 다음과 같습니다.

```sql
CHANGE MASTER TO
  MASTER_HOST='192.168.44.51',
  MASTER_PORT=3306,
  MASTER_USER='ir_repl',
  MASTER_PASSWORD='<REPLICATION_PASSWORD>',
  MASTER_USE_GTID=slave_pos,
  MASTER_CONNECT_RETRY=10;

START SLAVE;
```

복구된 기존 Primary는 MaxScale의 `auto_rejoin=true` 정책에 따라 현재 Primary의 Replica로 재편입됩니다. 기존 서버로 역할을 되돌릴 때는 복제 상태와 GTID를 확인한 뒤 수동 Switchover를 수행합니다.

