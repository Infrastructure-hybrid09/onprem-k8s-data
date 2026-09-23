#!/usr/bin/env bash
set -Eeuo pipefail

# MariaDB NFS dump 보관 정책: 7일 → 30일
# db-primary와 db-replica 양쪽에서 각각 실행한다.
# 실제 백업 생성은 스크립트가 @@read_only를 확인해 writable Primary에서만 수행한다.

DB_BACKUP_SCRIPT='/usr/local/sbin/db-backup.sh'
CRON_FILE='/etc/cron.d/infraready-db-backup'
TARGET_RETENTION_DAYS=30
STAMP=$(date +%Y%m%d-%H%M%S)

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

[[ -f "$DB_BACKUP_SCRIPT" ]] || {
  echo "ERROR: 백업 스크립트가 없습니다: $DB_BACKUP_SCRIPT" >&2
  exit 10
}

[[ -f "$CRON_FILE" ]] || {
  echo "ERROR: 백업 Cron 파일이 없습니다: $CRON_FILE" >&2
  exit 11
}

# 예상한 기존 7일 설정이 아닐 경우 임의 변경하지 않는다.
grep -qF 'KEEP_DAYS=${KEEP_DAYS:-7}' "$DB_BACKUP_SCRIPT" || {
  echo 'ERROR: db-backup.sh의 예상 기본 보관값(7일)을 찾지 못했습니다.' >&2
  exit 12
}

grep -q 'KEEP_DAYS=7' "$CRON_FILE" || {
  echo 'ERROR: Cron의 예상 보관값(7일)을 찾지 못했습니다.' >&2
  exit 13
}

cp -a "$DB_BACKUP_SCRIPT" "${DB_BACKUP_SCRIPT}.before-retention-${STAMP}"
cp -a "$CRON_FILE" "${CRON_FILE}.before-retention-${STAMP}"

sed -i \
  's/KEEP_DAYS=${KEEP_DAYS:-7}/KEEP_DAYS=${KEEP_DAYS:-30}/' \
  "$DB_BACKUP_SCRIPT"

sed -i 's/KEEP_DAYS=7/KEEP_DAYS=30/g' "$CRON_FILE"

bash -n "$DB_BACKUP_SCRIPT"

echo '=== 적용 결과 ==='
grep -n 'KEEP_DAYS' "$DB_BACKUP_SCRIPT"
grep -n 'db-backup.sh' "$CRON_FILE"
echo "MARIADB_BACKUP_RETENTION_OK days=${TARGET_RETENTION_DAYS}"
echo "SCRIPT_BACKUP=${DB_BACKUP_SCRIPT}.before-retention-${STAMP}"
echo "CRON_BACKUP=${CRON_FILE}.before-retention-${STAMP}"
