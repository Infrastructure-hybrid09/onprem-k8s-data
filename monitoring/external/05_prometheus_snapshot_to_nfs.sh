#!/usr/bin/env bash
set -Eeuo pipefail

NFS_SERVER='192.168.44.61'
NFS_EXPORT='/backup/prometheus'
NFS_MOUNT='/mnt/prometheus-backup-rw'
PROMETHEUS_DATA='/var/lib/prometheus'
API_URL='http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot?skip_head=false'

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

command -v curl >/dev/null
command -v jq >/dev/null
command -v tar >/dev/null
command -v sha256sum >/dev/null

install -d -o root -g root -m 0755 "$NFS_MOUNT"

if ! mountpoint -q "$NFS_MOUNT"; then
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

echo "SNAPSHOT_OK: $ARCHIVE"
