#!/usr/bin/env bash
set -Eeuo pipefail

DASHBOARD_DIR='/var/lib/grafana/dashboards'
GRAFANA_HEALTH_URL='http://192.168.14.73:3000/api/health'
STAMP=$(date +%Y%m%d-%H%M%S)
TEMP_FILE=$(mktemp /tmp/mariadb-up-count.XXXXXX.json)

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

echo '[1/6] MariaDB 2대 상태 패널이 있는 대시보드를 찾습니다.'
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


root = Path(sys.argv[1])
matches = []
for path in sorted(root.rglob("*.json")):
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue
    for panel in walk_panels(document):
        title = " ".join(str(panel.get("title", "")).split())
        expressions = "\n".join(
            str(target.get("expr", ""))
            for target in panel.get("targets", [])
            if isinstance(target, dict)
        )
        if title == "MariaDB 2대 상태" or "sum(mysql_up" in expressions:
            matches.append(str(path))

if len(matches) != 1:
    print(
        "ERROR: 대상 패널이 정확히 1개여야 합니다. "
        f"found={len(matches)} matches={matches}",
        file=sys.stderr,
    )
    raise SystemExit(10)

print(matches[0])
PY
)

BACKUP="${DASHBOARD}.before-mariadb-count-${STAMP}"
echo "DASHBOARD=$DASHBOARD"

echo '[2/6] 대시보드를 백업합니다.'
cp -a -- "$DASHBOARD" "$BACKUP"

echo '[3/6] MariaDB 상태를 정상 인스턴스 개수로 변경합니다.'
python3 - "$DASHBOARD" "$TEMP_FILE" <<'PY'
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


source = Path(sys.argv[1])
target = Path(sys.argv[2])
dashboard = json.loads(source.read_text(encoding="utf-8"))

matches = []
for panel in walk_panels(dashboard):
    title = " ".join(str(panel.get("title", "")).split())
    expressions = "\n".join(
        str(item.get("expr", ""))
        for item in panel.get("targets", [])
        if isinstance(item, dict)
    )
    if title == "MariaDB 2대 상태" or "sum(mysql_up" in expressions:
        matches.append(panel)

if len(matches) != 1:
    raise SystemExit(f"ERROR: 수정 대상 패널 수가 올바르지 않습니다. found={len(matches)}")

panel = matches[0]
panel["title"] = "MariaDB 2대 상태"
panel["description"] = (
    "정상적으로 접속 가능한 MariaDB 인스턴스 수입니다. "
    "2=두 대 정상, 1=한 대 장애, 0=두 대 장애입니다."
)
panel["fieldConfig"] = {
    "defaults": {
        "color": {"mode": "thresholds"},
        "decimals": 0,
        "thresholds": {
            "mode": "absolute",
            "steps": [
                {"color": "red", "value": None},
                {"color": "yellow", "value": 1},
                {"color": "green", "value": 2},
            ],
        },
    },
    "overrides": [],
}
panel["targets"] = [{
    "editorMode": "code",
    "expr": 'sum(mysql_up{job="mariadb"}) or vector(0)',
    "instant": True,
    "refId": "A",
}]

dashboard["version"] = int(dashboard.get("version") or 0) + 1
target.write_text(
    json.dumps(dashboard, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

echo '[4/6] 수정된 JSON을 검증합니다.'
jq empty "$TEMP_FILE"
jq -e '
  [.. | objects | select(.title? == "MariaDB 2대 상태")]
  | length == 1
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
  echo 'ERROR: Grafana Ready 확인 실패. 기존 파일로 복구했습니다.' >&2
  exit 4
fi

echo '[6/6] 적용 결과를 확인합니다.'
jq -r '
  .. | objects
  | select(.title? == "MariaDB 2대 상태")
  | "PANEL=\(.title) QUERY=\(.targets[0].expr)"
' "$DASHBOARD"

echo 'MARIADB_UP_COUNT_PANEL_READY'
echo "DASHBOARD_BACKUP=$BACKUP"
