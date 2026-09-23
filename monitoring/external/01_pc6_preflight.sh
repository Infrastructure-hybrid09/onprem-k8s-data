#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_HOSTNAME=monitoring

echo '[1/7] Hostname and OS'
hostnamectl
cat /etc/os-release

ACTUAL_HOSTNAME=$(hostname -s)
if [[ "$ACTUAL_HOSTNAME" != "$EXPECTED_HOSTNAME" ]]; then
  echo "ERROR: expected hostname=$EXPECTED_HOSTNAME, actual=$ACTUAL_HOSTNAME" >&2
  exit 9
fi

echo '[2/7] Interfaces and addresses'
nmcli device status
ip -br address show

echo '[3/7] Routing'
ip route

DEFAULT_ROUTES=$(ip -4 route show default | wc -l)
if [[ "$DEFAULT_ROUTES" -ne 1 ]]; then
  echo "ERROR: IPv4 default route must be exactly one; found $DEFAULT_ROUTES" >&2
  exit 10
fi

echo '[4/7] Block devices'
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL

echo '[5/7] Capacity'
free -h
df -hT

echo '[6/7] Required TCP paths'
command -v nc >/dev/null || {
  echo 'ERROR: nc is required. Install nmap-ncat first.' >&2
  exit 11
}

check_tcp() {
  local host=$1
  local port=$2
  local name=$3
  if nc -z -w 3 "$host" "$port"; then
    printf 'OK   %-24s %s:%s\n' "$name" "$host" "$port"
  else
    printf 'FAIL %-24s %s:%s\n' "$name" "$host" "$port" >&2
    return 1
  fi
}

FAILED=0
check_tcp 192.168.34.100 6443 'Main K8s API VIP' || FAILED=1
check_tcp 192.168.34.71 6443 'DR K3s API' || FAILED=1
check_tcp 192.168.34.71 9100 'DR Node Exporter' || FAILED=1
check_tcp 192.168.44.51 9104 'DB Primary Exporter' || FAILED=1
check_tcp 192.168.44.52 9104 'DB Replica Exporter' || FAILED=1
check_tcp 192.168.44.61 2049 'NFS' || FAILED=1
check_tcp 192.168.44.72 9000 'MinIO API' || FAILED=1

echo '[7/7] Firewalld'
systemctl is-active firewalld || true
firewall-cmd --get-active-zones 2>/dev/null || true
firewall-cmd --list-all-zones 2>/dev/null || true

if [[ "$FAILED" -ne 0 ]]; then
  echo 'PC6_PREFLIGHT_FAILED: resolve failed network paths before installation.' >&2
  exit 20
fi

echo 'PC6_PREFLIGHT_OK'
