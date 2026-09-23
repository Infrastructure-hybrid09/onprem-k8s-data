#!/usr/bin/env bash
set -Eeuo pipefail

NFS_SERVER='192.168.44.61'
NFS_EXPORT='/backup/prometheus'
NFS_MOUNT='/mnt/prometheus-backup-rw'
PROMETHEUS_DATA='/var/lib/prometheus'
API_URL='http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot?skip_head=false'
RETENTION_DAYS=14

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

command -v curl >/dev/null
command -v jq >/dev/null
command -v tar >/dev/null
command -v sha256sum >/dev/null

# 이미 NFS가 마운트된 상태에서는 소유권·권한을 변경하지 않는다.
# NFS root_squash 환경에서 chown/chmod 시도는 실패한다.
if ! mountpoint -q "$NFS_MOUNT"; then
  install -d -o root -g root -m 0755 "$NFS_MOUNT"
  mount -t nfs -o rw "$NFS_SERVER:$NFS_EXPORT" "$NFS_MOUNT"
fi

SNAP_NAME=$(curl -fsS -X POST "$API_URL" | jq -r '.data.name')
[[ -n "$SNAP_NAME" && "$SNAP_NAME" != 'null' ]] || {
  echo 'ERROR: Prometheus snapshot 이름을 받지 못했습니다.' >&2
  exit 10
}

SNAP_DIR="$PROMETHEUS_DATA/snapshots/$SNAP_NAME"
for _ in $(seq 1 60); do
  [[ -d "$SNAP_DIR" ]] && break
  sleep 1
done

[[ -d "$SNAP_DIR" ]] || {
  echo "ERROR: snapshot 디렉터리가 생성되지 않았습니다: $SNAP_DIR" >&2
  exit 11
}

ARCHIVE="$NFS_MOUNT/prometheus_${SNAP_NAME}.tar.gz"
CHECKSUM="${ARCHIVE}.sha256"
TEMP_ARCHIVE="${ARCHIVE}.tmp.$$.tar.gz"

tar -czf "$TEMP_ARCHIVE" \
  -C "$PROMETHEUS_DATA/snapshots" \
  "$SNAP_NAME"

mv -f -- "$TEMP_ARCHIVE" "$ARCHIVE"

(
  cd "$NFS_MOUNT"
  sha256sum "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")"
)

(
  cd "$NFS_MOUNT"
  sha256sum -c "$(basename "$CHECKSUM")" >/dev/null
)
gzip -t "$ARCHIVE"

rm -rf -- "$SNAP_DIR"

while IFS= read -r -d '' OLD_ARCHIVE; do
  OLD_CHECKSUM="${OLD_ARCHIVE}.sha256"
  echo "RETENTION_DELETE: $OLD_ARCHIVE"
  rm -f -- "$OLD_ARCHIVE" "$OLD_CHECKSUM"
done < <(
  find "$NFS_MOUNT" \
    -maxdepth 1 \
    -type f \
    -name 'prometheus_*.tar.gz' \
    -mtime +13 \
    -print0
)

# 아카이브 없이 남아 있는 오래된 체크섬 파일도 정리한다.
find "$NFS_MOUNT" \
  -maxdepth 1 \
  -type f \
  -name 'prometheus_*.tar.gz.sha256' \
  -mtime +13 \
  -delete

echo "SNAPSHOT_OK: $ARCHIVE"
