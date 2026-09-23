#!/usr/bin/env bash
# NFS 백업을 MinIO nfs-backup 버킷에 2차 사본으로 복사한다.
# 의도적으로 --remove를 사용하지 않아 NFS의 실수 삭제를 MinIO에 전파하지 않는다.
set -Eeuo pipefail

: "${MINIO_ENDPOINT:?MINIO_ENDPOINT is required}"
: "${MINIO_ACCESS_KEY:?MINIO_ACCESS_KEY is required}"
: "${MINIO_SECRET_KEY:?MINIO_SECRET_KEY is required}"

SOURCE="${SOURCE:-/backup}"
ALIAS="${MINIO_ALIAS:-infraready-minio}"
BUCKET="${MINIO_BUCKET:-nfs-backup}"
PREFIX="${MINIO_PREFIX:-nfs-data}"
LOCK_FILE="/run/lock/infraready-nfs-to-minio.lock"

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

# 자체 서명 인증서를 쓰는 경우에는 시스템 CA에 먼저 등록하는 방식을 권장한다.
mc alias set "$ALIAS" "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY"
mc mb --ignore-existing "$ALIAS/$BUCKET"
mc mirror --overwrite "$SOURCE" "$ALIAS/$BUCKET/$PREFIX"

