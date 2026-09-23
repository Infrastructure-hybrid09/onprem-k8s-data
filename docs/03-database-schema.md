# 데이터베이스 스키마

`infraready` 데이터베이스는 MariaDB 11.8, InnoDB, `utf8mb4`를 기준으로 구성합니다.

- 전체 테이블: 23개
- 기본 서비스: 12개
- AI 기능: 5개
- AI 토큰 관리: 2개
- 학습 운영: 4개

전체 신규 구축용 DDL은 [01_infraready_schema.sql](../sql/01_infraready_schema.sql)에 있습니다. 최신 테이블 목록 문서에만 존재하던 다음 항목도 실제 DDL로 반영했습니다.

- `user_notifications`
- `question_reports`
- `ai_problem_bank_settings`
- `user_active_plans`
- `diagnosis_questions.content_hash`
- `question_no` 범위 `1~1000`

`user_subjects.focus_topic`은 운영 DB 점검 당시 존재하지 않았으므로 기본 DDL에 임의로 추가하지 않았습니다.

DDL은 현재 쓰기 가능한 Primary에서 한 번만 적용하고, Replica에는 GTID 복제로 전파합니다. 운영 환경에서는 Spring JPA의 `ddl-auto`를 `validate`로 사용합니다.

