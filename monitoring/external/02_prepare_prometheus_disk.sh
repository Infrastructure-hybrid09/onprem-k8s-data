#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: run with sudo: sudo $0 /dev/<data-disk>" >&2
  exit 2
fi

for REQUIRED_COMMAND in lsblk findmnt wipefs blockdev parted partprobe udevadm mkfs.xfs blkid; do
  command -v "$REQUIRED_COMMAND" >/dev/null || {
    echo "ERROR: required command not found: $REQUIRED_COMMAND" >&2
    echo 'Install parted, xfsprogs and util-linux before retrying.' >&2
    exit 12
  }
done

DEVICE=${1:-}
MOUNT_POINT=/var/lib/prometheus

if [[ -z "$DEVICE" ]]; then
  echo "Usage: sudo $0 /dev/<data-disk>" >&2
  exit 3
fi

DEVICE=$(readlink -f -- "$DEVICE")
[[ -b "$DEVICE" ]] || { echo "ERROR: not a block device: $DEVICE" >&2; exit 4; }

ROOT_SOURCE=$(findmnt -n -o SOURCE /)
ROOT_PARENT=$(lsblk -ndo PKNAME "$ROOT_SOURCE" 2>/dev/null || true)
if [[ -n "$ROOT_PARENT" && "$DEVICE" == "/dev/$ROOT_PARENT" ]]; then
  echo "ERROR: selected device is the OS root disk: $DEVICE" >&2
  exit 5
fi

if findmnt -rn -S "$DEVICE" >/dev/null 2>&1; then
  echo "ERROR: device is already mounted: $DEVICE" >&2
  exit 6
fi

CHILD_COUNT=$(lsblk -nr -o TYPE "$DEVICE" | awk '$1=="part"{n++} END{print n+0}')
if [[ "$CHILD_COUNT" -ne 0 ]]; then
  echo "ERROR: device already has partitions: $DEVICE" >&2
  lsblk "$DEVICE"
  exit 7
fi

if wipefs -n "$DEVICE" | grep -q .; then
  echo "ERROR: existing filesystem or partition signature found: $DEVICE" >&2
  wipefs -n "$DEVICE"
  exit 8
fi

SIZE_BYTES=$(blockdev --getsize64 "$DEVICE")
MIN_BYTES=$((25 * 1024 * 1024 * 1024))
if [[ "$SIZE_BYTES" -lt "$MIN_BYTES" ]]; then
  echo "ERROR: data disk must be at least 25GiB: $DEVICE" >&2
  exit 9
fi

echo 'Selected disk:'
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "$DEVICE"
echo
echo "This creates one GPT/XFS partition and mounts it at $MOUNT_POINT."
read -r -p 'Type FORMAT-PROMETHEUS-DISK to continue: ' ANSWER
[[ "$ANSWER" == 'FORMAT-PROMETHEUS-DISK' ]] || { echo 'Cancelled'; exit 1; }

parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart primary xfs 1MiB 100%
partprobe "$DEVICE"
udevadm settle

PARTITION="${DEVICE}1"
if [[ "$DEVICE" =~ (nvme|mmcblk) ]]; then
  PARTITION="${DEVICE}p1"
fi
[[ -b "$PARTITION" ]] || { echo "ERROR: partition not found: $PARTITION" >&2; exit 10; }

# XFS filesystem labels are limited to 12 characters.
mkfs.xfs -f -L prom-data "$PARTITION"
install -d -o root -g root -m 0755 "$MOUNT_POINT"

UUID=$(blkid -s UUID -o value "$PARTITION")
[[ -n "$UUID" ]] || { echo 'ERROR: UUID not found' >&2; exit 11; }

FSTAB_LINE="UUID=$UUID $MOUNT_POINT xfs defaults,nofail 0 2"
grep -q "UUID=$UUID" /etc/fstab || printf '%s\n' "$FSTAB_LINE" >> /etc/fstab
mount "$MOUNT_POINT"

install -d -o root -g root -m 0755 "$MOUNT_POINT"

findmnt "$MOUNT_POINT"
df -hT "$MOUNT_POINT"
ls -ldnZ "$MOUNT_POINT"
echo 'PROMETHEUS_DATA_DISK_READY'
