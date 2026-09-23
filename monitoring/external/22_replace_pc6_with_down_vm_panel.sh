#!/usr/bin/env bash
set -Eeuo pipefail

DASHBOARD_DIR='/var/lib/grafana/dashboards'
GRAFANA_HEALTH_URL='http://192.168.14.73:3000/api/health'
STAMP=$(date +%Y%m%d-%H%M%S)
TEMP_FILE=$(mktemp /tmp/observability-down-vm.XXXXXX.json)

cleanup() {
  rm -f -- "$TEMP_FILE"
}
trap cleanup EXIT

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

for command_name in python3 jq curl systemctl; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 2
  }
done

[[ -d "$DASHBOARD_DIR" ]] || {
  echo "ERROR: 대시보드 디렉터리가 없습니다: $DASHBOARD_DIR" >&2
  exit 3
}

echo '[1/6] PC6 VM 합계 패널이 들어 있는 실제 대시보드 파일을 찾습니다.'
DASHBOARD=$(
  python3 - "$DASHBOARD_DIR" <<'PY'
import json
from pathlib import Path
import sys


def walk_panels(value):
    if isinstance(value, dict):
        if "title" in value and "targets" in value:
            yield value
        for child in value.values():
            yield from walk_panels(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_panels(child)


def is_target_panel(panel):
    title = " ".join(str(panel.get("title", "")).split())
    expressions = "\n".join(
        str(item.get("expr", ""))
        for item in panel.get("targets", [])
        if isinstance(item, dict)
    )
    return (
        title in {"PC6 VM UP (목표 2)", "현재 장애 VM"}
        or ("PC6" in title and "VM" in title and "UP" in title)
        or (
            "192.168.14.72:9100" in expressions
            and "192.168.34.71:9100" in expressions
            and "sum(" in expressions
        )
    )


root = Path(sys.argv[1])
matches = []
invalid = []
for path in sorted(root.rglob("*.json")):
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        invalid.append(str(path))
        continue
    count = sum(1 for panel in walk_panels(document) if is_target_panel(panel))
    if count:
        matches.extend([str(path)] * count)

if len(matches) != 1:
    print(
        "ERROR: 전체 대시보드에서 교체 대상 패널이 정확히 1개여야 합니다. "
        f"found={len(matches)} matches={matches}",
        file=sys.stderr,
    )
    raise SystemExit(10)

print(matches[0])
PY
)

[[ -s "$DASHBOARD" ]] || {
  echo 'ERROR: 검색된 대시보드 파일이 없거나 비어 있습니다.' >&2
  exit 4
}

BACKUP="${DASHBOARD}.before-down-vm-${STAMP}"
echo "DASHBOARD=$DASHBOARD"

echo '[2/6] 대상 대시보드를 백업합니다.'
cp -a -- "$DASHBOARD" "$BACKUP"

echo '[3/6] PC6 VM 합계 패널을 현재 장애 VM 패널로 교체합니다.'
python3 - "$DASHBOARD" "$TEMP_FILE" <<'PY'
import json
from pathlib import Path
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
dashboard = json.loads(source.read_text(encoding="utf-8"))


def walk_panels(value):
    if isinstance(value, dict):
        if "title" in value and "targets" in value:
            yield value
        for child in value.values():
            yield from walk_panels(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_panels(child)


def is_target_panel(panel):
    title = " ".join(str(panel.get("title", "")).split())
    expressions = "\n".join(
        str(item.get("expr", ""))
        for item in panel.get("targets", [])
        if isinstance(item, dict)
    )
    title_match = (
        title in {"PC6 VM UP (목표 2)", "현재 장애 VM"}
        or ("PC6" in title and "VM" in title and "UP" in title)
    )
    old_query_match = (
        "192.168.14.72:9100" in expressions
        and "192.168.34.71:9100" in expressions
        and "sum(" in expressions
    )
    return title_match or old_query_match


all_panels = list(walk_panels(dashboard))
matches = [panel for panel in all_panels if is_target_panel(panel)]
if len(matches) != 1:
    candidate_titles = [
        str(panel.get("title"))
        for panel in all_panels
        if "PC6" in str(panel.get("title", ""))
        or "VM" in str(panel.get("title", ""))
    ]
    raise SystemExit(
        "ERROR: 교체 대상 패널이 정확히 1개여야 합니다. "
        f"found={len(matches)} candidates={candidate_titles}"
    )

panel = matches[0]
targets = [
    ("A", "node-exporter-vm", "192.168.14.11:9100", "lb1 (192.168.14.11)"),
    ("B", "node-exporter-vm", "192.168.14.12:9100", "lb2 (192.168.14.12)"),
    ("C", "node-exporter-vm", "192.168.14.21:9100", "devops/maxscale (192.168.14.21)"),
    ("D", "node-exporter-vm", "192.168.14.51:9100", "db-primary (192.168.14.51)"),
    ("E", "node-exporter-vm", "192.168.14.52:9100", "db-replica (192.168.14.52)"),
    ("F", "node-exporter-vm", "192.168.14.61:9100", "nfs (192.168.14.61)"),
    ("G", "node-exporter-vm", "192.168.14.62:9100", "infra (192.168.14.62)"),
    ("H", "node-exporter-vm", "192.168.14.72:9100", "minio (192.168.14.72)"),
    ("I", "node-exporter-k8s-existing", "192.168.34.31:9100", "control1 (192.168.34.31)"),
    ("J", "node-exporter-k8s-existing", "192.168.34.32:9100", "control2 (192.168.34.32)"),
    ("K", "node-exporter-k8s-existing", "192.168.34.33:9100", "control3 (192.168.34.33)"),
    ("L", "node-exporter-k8s-existing", "192.168.34.41:9100", "worker1 (192.168.34.41)"),
    ("M", "node-exporter-k8s-existing", "192.168.34.42:9100", "worker2 (192.168.34.42)"),
    ("N", "node-exporter-k8s-existing", "192.168.34.43:9100", "worker3 (192.168.34.43)"),
    ("O", "node-exporter-k8s-existing", "192.168.34.71:9100", "dr-k3s (192.168.34.71)"),
    ("P", "monitoring-node", "monitoring", "monitoring (192.168.14.73)"),
]

panel.update({
    "title": "현재 장애 VM",
    "description": (
        "Node Exporter 수집이 실패한 VM만 표시합니다. 모두 정상이면 "
        "'장애 VM 없음'으로 표시됩니다. VM 자체 장애뿐 아니라 "
        "Node Exporter 또는 네트워크 장애도 포함됩니다."
    ),
    "type": "stat",
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "thresholds"},
            "decimals": 0,
            "mappings": [{
                "options": {
                    "0": {"color": "red", "text": "DOWN"},
                    "1": {"color": "green", "text": "장애 VM 없음"},
                },
                "type": "value",
            }],
            "thresholds": {
                "mode": "absolute",
                "steps": [
                    {"color": "red", "value": None},
                    {"color": "green", "value": 1},
                ],
            },
        },
        "overrides": [],
    },
    "options": {
        "colorMode": "background",
        "graphMode": "none",
        "orientation": "vertical",
        "reduceOptions": {"calcs": ["lastNotNull"], "values": False},
        "textMode": "value_and_name",
        "wideLayout": True,
    },
    "targets": [
        {
            "editorMode": "code",
            "expr": f'up{{job="{job}",instance="{instance}"}} == 0',
            "instant": True,
            "legendFormat": name,
            "refId": ref_id,
        }
        for ref_id, job, instance, name in targets
    ] + [{
        "editorMode": "code",
        "expr": (
            'vector(1) unless (count(up{job=~"node-exporter-vm|'
            'node-exporter-k8s-existing|monitoring-node"} == 0) > 0)'
        ),
        "instant": True,
        "legendFormat": "정상",
        "refId": "Z",
    }],
})

dashboard["version"] = int(dashboard.get("version") or 0) + 1
target.write_text(
    json.dumps(dashboard, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

echo '[4/6] 수정된 대시보드 JSON을 검증합니다.'
jq empty "$TEMP_FILE"
jq -e '
  [.. | objects | select(.title? == "현재 장애 VM")] | length == 1
' "$TEMP_FILE" >/dev/null

echo '[5/6] 대시보드를 적용하고 Grafana를 재시작합니다.'
install -o 472 -g 472 -m 0640 "$TEMP_FILE" "$DASHBOARD"
restorecon -F "$DASHBOARD" 2>/dev/null || true
systemctl restart grafana.service

for _ in $(seq 1 30); do
  if curl -fsS "$GRAFANA_HEALTH_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "$GRAFANA_HEALTH_URL" >/dev/null; then
  cp -a -- "$BACKUP" "$DASHBOARD"
  systemctl restart grafana.service || true
  echo 'ERROR: Grafana Ready 확인 실패. 기존 대시보드로 복구했습니다.' >&2
  exit 4
fi

echo '[6/6] 적용 결과를 확인합니다.'
jq -r '
  .. | objects
  | select(.title == "현재 장애 VM")
  | "PANEL=\(.title) TARGET_QUERIES=\(.targets | length)"
' "$DASHBOARD"

echo 'DOWN_VM_PANEL_READY'
echo "DASHBOARD_BACKUP=$BACKUP"
