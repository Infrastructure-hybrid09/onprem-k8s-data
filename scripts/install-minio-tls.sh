#!/usr/bin/env bash
# 사전에 발급한 MinIO 서버 인증서와 개인키를 MinIO 표준 경로에 설치한다.
# 사용법: install-minio-tls.sh /path/public.crt /path/private.key
set -Eeuo pipefail

CERT_SOURCE="${1:?public certificate path is required}"
KEY_SOURCE="${2:?private key path is required}"
MINIO_USER="${MINIO_USER:-minio-user}"
MINIO_GROUP="${MINIO_GROUP:-minio-user}"
MINIO_HOME="$(getent passwd "$MINIO_USER" | cut -d: -f6)"
CERT_DIR="$MINIO_HOME/.minio/certs"

[[ -s "$CERT_SOURCE" && -s "$KEY_SOURCE" ]]
install -d -m 0700 -o "$MINIO_USER" -g "$MINIO_GROUP" "$CERT_DIR"
install -m 0644 -o "$MINIO_USER" -g "$MINIO_GROUP" "$CERT_SOURCE" "$CERT_DIR/public.crt"
install -m 0600 -o "$MINIO_USER" -g "$MINIO_GROUP" "$KEY_SOURCE" "$CERT_DIR/private.key"
systemctl restart minio

