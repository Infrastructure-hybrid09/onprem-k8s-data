# MariaDB 계정과 권한

| 계정 | 접속 원본 | 용도 |
| --- | --- | --- |
| `ir_app` | MaxScale `192.168.44.21` | 애플리케이션 DML |
| `ir_repl` | 상대 DB 서버 | GTID 복제 |
| `mxs_mon` | MaxScale | DB 상태 감시·승격·재조인 |
| `mxs_route` | MaxScale | 사용자·권한 조회 |
| `ir_exporter` | localhost | MariaDB 메트릭 수집 |
| `ir_backup` | localhost | 논리 백업 |

계정 생성 예제는 [03_create_service_accounts.sql](../sql/03_create_service_accounts.sql)에 있습니다. 실제 비밀번호는 코드에 기록하지 않고 배포 시 주입합니다.

계정은 현재 쓰기 가능한 Primary에서 생성합니다. 생성된 계정과 권한은 GTID 복제를 통해 Replica에 전달됩니다.

