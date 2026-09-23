#!/usr/bin/env bash
# nfs-backup·loki-data 버킷과 최소권한 서비스 계정을 구성한다.
# 민감정보는 환경변수로만 전달하고 파일에 직접 기록하지 않는다.
set -Eeuo pipefail

: "${MINIO_ENDPOINT:?MINIO_ENDPOINT is required}"
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER is required}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD is required}"
: "${NFS_BACKUP_USER:?NFS_BACKUP_USER is required}"
: "${NFS_BACKUP_PASSWORD:?NFS_BACKUP_PASSWORD is required}"
: "${LOKI_USER:?LOKI_USER is required}"
: "${LOKI_PASSWORD:?LOKI_PASSWORD is required}"

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ALIAS="infraready-minio-admin"

mc alias set "$ALIAS" "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
mc mb --ignore-existing "$ALIAS/nfs-backup"
mc mb --ignore-existing "$ALIAS/loki-data"

mc admin policy create "$ALIAS" nfs-backup-rw "$ROOT_DIR/configs/minio/nfs-backup-policy.json"
mc admin policy create "$ALIAS" loki-data-rw "$ROOT_DIR/configs/minio/loki-data-policy.json"

mc admin user add "$ALIAS" "$NFS_BACKUP_USER" "$NFS_BACKUP_PASSWORD"
mc admin policy attach "$ALIAS" nfs-backup-rw --user "$NFS_BACKUP_USER"
mc admin user add "$ALIAS" "$LOKI_USER" "$LOKI_PASSWORD"
mc admin policy attach "$ALIAS" loki-data-rw --user "$LOKI_USER"

