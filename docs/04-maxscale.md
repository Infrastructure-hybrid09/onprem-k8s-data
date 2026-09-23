# MaxScale 구성

현재 구성의 MaxScale 버전은 `25.01`입니다. 구버전 PDF의 `24.02` 설정은 사용하지 않습니다.

```text
Backend → 192.168.44.21:4006 → 현재 MariaDB Primary
```

핵심 정책:

| 설정 | 값 | 의미 |
| --- | --- | --- |
| `router` | `readwritesplit` | 쓰기는 Primary, 읽기는 역할에 따라 분산 |
| `monitor_interval` | `2000ms` | 2초 간격 상태 확인 |
| `auto_failover` | `true` | Primary 장애 시 Replica 자동 승격 |
| `auto_rejoin` | `true` | 복구 서버를 Replica로 자동 재편입 |
| `auto_failback_switchover` | `false` | 기존 서버로 자동 역할 원복하지 않음 |

- 설정 예제: [maxscale.cnf.example](../configs/maxscale/maxscale.cnf.example)

실제 비밀번호는 설정 예제에 기록하지 않고 `<..._PASSWORD>` 자리표시자로 분리했습니다.

MaxScale은 수동으로 구축했습니다. 이후 작성된 Ansible Playbook은 실제 구축에 실행하지 않았으므로 이 저장소에서 제외했습니다.
