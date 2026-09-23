#!/usr/bin/env bash
# 쓰기 가능한 MariaDB Primary에서만 논리 백업을 생성한다.
# NFS 보존 기간은 30일이며 비밀번호는 /root/.my.cnf 등 클라이언트 설정에서 읽는다.
set -Eeuo pipefail

BACKUP_DIR="${BACKUP_DIR:-/mnt/db-backup}"
DATABASE="${DATABASE:-infraready}"
KEEP_DAYS="${KEEP_DAYS:-30}"
STAMP="$(date +%Y%m%d_%H%M%S)"
TARGET="$BACKUP_DIR/${DATABASE}_${STAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

# Replica에서는 동일 백업이 중복 생성되지 않도록 종료한다.
READ_ONLY="$(mariadb -Nse 'SELECT @@global.read_only')"
[[ "$READ_ONLY" == "0" ]] || exit 0

mariadb-dump \
  --single-transaction \
  --routines --events --triggers \
  --hex-blob \
  --databases "$DATABASE" \
  | gzip -1 >"$TARGET"

gzip -t "$TARGET"
sha256sum "$TARGET" >"$TARGET.sha256"
find "$BACKUP_DIR" -maxdepth 1 -type f \
  \( -name "${DATABASE}_*.sql.gz" -o -name "${DATABASE}_*.sql.gz.sha256" \) \
  -mtime "+$KEEP_DAYS" -delete

