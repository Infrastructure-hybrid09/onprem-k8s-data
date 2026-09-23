#!/usr/bin/env bash
# InfraReady 1차 백업 저장소(NFS)를 구성한다.
# 실행 위치: NFS VM(192.168.44.61), root 권한
set -Eeuo pipefail

EXPORT_ROOT="${EXPORT_ROOT:-/backup}"
EXPORT_FILE="/etc/exports.d/infraready-backup.exports"

dnf install -y nfs-utils policycoreutils-python-utils acl

# 백업 종류별 디렉터리를 분리한다.
install -d -m 0770 "$EXPORT_ROOT/mariadb" "$EXPORT_ROOT/etcd" "$EXPORT_ROOT/prometheus" "$EXPORT_ROOT/config"
chown -R nobody:nobody "$EXPORT_ROOT"

install -d -m 0755 /etc/exports.d
install -m 0644 /dev/null "$EXPORT_FILE"
cat >"$EXPORT_FILE" <<EOF
$EXPORT_ROOT/mariadb   192.168.44.51(rw,sync,all_squash,no_subtree_check) 192.168.44.52(rw,sync,all_squash,no_subtree_check)
$EXPORT_ROOT/etcd      192.168.44.0/24(rw,sync,all_squash,no_subtree_check)
$EXPORT_ROOT/prometheus 192.168.44.73(rw,sync,all_squash,no_subtree_check)
$EXPORT_ROOT/config    192.168.44.0/24(rw,sync,all_squash,no_subtree_check)
EOF

setsebool -P nfs_export_all_rw 1
systemctl enable --now rpcbind nfs-server
exportfs -rav
