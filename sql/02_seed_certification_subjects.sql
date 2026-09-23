-- 자격증 과목 4종 등록
-- 대상: infraready.subjects
-- 특징: subjects.code의 UNIQUE 제약조건을 이용해 재실행해도 중복 생성하지 않는다.

SET NAMES utf8mb4;

START TRANSACTION;

INSERT INTO subjects (
    code,
    name,
    is_active,
    created_at
)
VALUES
    ('INFORMATION_PROCESSING_WRITTEN',   '정보처리기사 · 필기',    1, CURRENT_TIMESTAMP(6)),
    ('INFORMATION_PROCESSING_PRACTICAL', '정보처리기사 · 실기',    1, CURRENT_TIMESTAMP(6)),
    ('LINUX_MASTER_2_FIRST',             '리눅스마스터 2급 · 1차', 1, CURRENT_TIMESTAMP(6)),
    ('LINUX_MASTER_2_SECOND',            '리눅스마스터 2급 · 2차', 1, CURRENT_TIMESTAMP(6))
ON DUPLICATE KEY UPDATE
    name = VALUES(name),
    is_active = VALUES(is_active);

COMMIT;

SELECT
    id,
    code,
    name,
    is_active,
    created_at
FROM subjects
WHERE code IN (
    'INFORMATION_PROCESSING_WRITTEN',
    'INFORMATION_PROCESSING_PRACTICAL',
    'LINUX_MASTER_2_FIRST',
    'LINUX_MASTER_2_SECOND'
)
ORDER BY code;
