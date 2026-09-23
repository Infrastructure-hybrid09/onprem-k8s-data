#!/usr/bin/env bash
set -Eeuo pipefail

PROMETHEUS_IMAGE='quay.io/prometheus/prometheus:v3.13.1-distroless'
RULE_FILE='/etc/prometheus/rules/blackbox-alerts.yml'
DASHBOARD='/var/lib/grafana/dashboards/observability-platform.json'
STAMP=$(date +%Y%m%d-%H%M%S)
RULE_BACKUP="${RULE_FILE}.before-${STAMP}"
DASHBOARD_BACKUP="${DASHBOARD}.before-blackbox-${STAMP}"
DASHBOARD_TEMP=$(mktemp /tmp/observability-blackbox.XXXXXX.json)
RULE_EXISTED=false

cleanup() {
  rm -f -- "$DASHBOARD_TEMP"
}
trap cleanup EXIT

if [[ ${EUID} -ne 0 ]]; then
  echo 'ERROR: sudo로 실행하세요.' >&2
  exit 1
fi

for command_name in podman curl jq systemctl; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 2
  }
done

[[ -s "$DASHBOARD" ]] || {
  echo "ERROR: 대시보드 파일이 없습니다: $DASHBOARD" >&2
  exit 3
}

probe_count=$(
  curl -fsSG http://127.0.0.1:9090/api/v1/query \
    --data-urlencode 'query=count(probe_success{job="blackbox-neuroplan"} == 1)' |
    jq -r '.data.result[0].value[1] // "0"'
)
[[ "$probe_count" == '6' ]] || {
  echo "ERROR: 정상 Blackbox Probe가 6개가 아닙니다: $probe_count" >&2
  exit 4
}

echo '[1/5] Blackbox 전용 경보 규칙을 설치합니다.'
if [[ -e "$RULE_FILE" ]]; then
  RULE_EXISTED=true
  cp -a -- "$RULE_FILE" "$RULE_BACKUP"
fi

cat > "$RULE_FILE" <<'EOF'
groups:
  - name: infraready.blackbox
    interval: 30s
    rules:
      - alert: NeuroplanServiceProbeFailed
        expr: probe_success{job="blackbox-neuroplan"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "NeuroPlan 서비스 응답 실패: {{ $labels.node }} / {{ $labels.endpoint_type }}"
          description: "Monitoring VM의 Blackbox 점검이 {{ $labels.instance }}에서 1분 이상 실패했습니다."

      - alert: NeuroplanServiceSlowResponse
        expr: probe_duration_seconds{job="blackbox-neuroplan"} > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "NeuroPlan 서비스 응답 지연: {{ $labels.node }} / {{ $labels.endpoint_type }}"
          description: "{{ $labels.instance }}의 전체 Probe 시간이 5분 이상 2초를 초과했습니다."
EOF

chown root:root "$RULE_FILE"
chmod 0644 "$RULE_FILE"

podman run \
  --rm \
  --entrypoint=/bin/promtool \
  -v /etc/prometheus:/etc/prometheus:ro,Z \
  "$PROMETHEUS_IMAGE" \
  check rules \
  /etc/prometheus/rules/blackbox-alerts.yml

echo '[2/5] Prometheus에 경보 규칙을 반영합니다.'
if ! systemctl restart prometheus.service; then
  if $RULE_EXISTED; then
    cp -a -- "$RULE_BACKUP" "$RULE_FILE"
  else
    rm -f -- "$RULE_FILE"
  fi
  systemctl restart prometheus.service || true
  echo 'ERROR: Prometheus 재시작 실패. 경보 규칙을 복구했습니다.' >&2
  exit 5
fi

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9090/-/ready >/dev/null; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:9090/-/ready >/dev/null || {
  echo 'ERROR: Prometheus Ready 확인 실패.' >&2
  exit 6
}

echo '[3/5] Observability 대시보드에 서비스 가용성 패널을 추가합니다.'
cp -a -- "$DASHBOARD" "$DASHBOARD_BACKUP"

jq '
  .panels |= map(select(.id != 14 and .id != 15 and .id != 16)) |
  .panels += [
    {
      "datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},
      "fieldConfig":{
        "defaults":{
          "color":{"mode":"thresholds"},
          "mappings":[{"options":{"0":{"color":"red","text":"DOWN"},"1":{"color":"green","text":"UP"}},"type":"value"}],
          "thresholds":{"mode":"absolute","steps":[{"color":"red","value":null},{"color":"green","value":1}]}
        },
        "overrides":[]
      },
      "gridPos":{"h":6,"w":8,"x":0,"y":32},
      "id":14,
      "options":{"colorMode":"background","graphMode":"none","justifyMode":"auto","orientation":"auto","reduceOptions":{"calcs":["lastNotNull"],"fields":"","values":false},"textMode":"auto","wideLayout":true},
      "targets":[{"editorMode":"code","expr":"probe_success{job=\"blackbox-neuroplan\",endpoint_type=\"frontend\"}","legendFormat":"{{node}}","refId":"A"}],
      "title":"Main Frontend 가용성 (Worker NodePort)",
      "type":"stat"
    },
    {
      "datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},
      "fieldConfig":{
        "defaults":{
          "color":{"mode":"thresholds"},
          "mappings":[{"options":{"0":{"color":"red","text":"DOWN"},"1":{"color":"green","text":"UP"}},"type":"value"}],
          "thresholds":{"mode":"absolute","steps":[{"color":"red","value":null},{"color":"green","value":1}]}
        },
        "overrides":[]
      },
      "gridPos":{"h":6,"w":8,"x":8,"y":32},
      "id":15,
      "options":{"colorMode":"background","graphMode":"none","justifyMode":"auto","orientation":"auto","reduceOptions":{"calcs":["lastNotNull"],"fields":"","values":false},"textMode":"auto","wideLayout":true},
      "targets":[{"editorMode":"code","expr":"probe_success{job=\"blackbox-neuroplan\",endpoint_type=\"backend\"}","legendFormat":"{{node}}","refId":"A"}],
      "title":"Main Backend 가용성 (Worker NodePort)",
      "type":"stat"
    },
    {
      "datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},
      "fieldConfig":{"defaults":{"decimals":3,"unit":"s"},"overrides":[]},
      "gridPos":{"h":6,"w":8,"x":16,"y":32},
      "id":16,
      "options":{"legend":{"displayMode":"table","placement":"bottom","showLegend":true},"tooltip":{"mode":"multi"}},
      "targets":[{"editorMode":"code","expr":"probe_duration_seconds{job=\"blackbox-neuroplan\"}","legendFormat":"{{node}} {{endpoint_type}}","refId":"A"}],
      "title":"Main 서비스 Probe 응답시간",
      "type":"timeseries"
    }
  ] |
  .version = ((.version // 0) + 1)
' "$DASHBOARD" > "$DASHBOARD_TEMP"

jq empty "$DASHBOARD_TEMP"
install -o 472 -g 472 -m 0640 "$DASHBOARD_TEMP" "$DASHBOARD"
restorecon -F "$DASHBOARD" 2>/dev/null || true

echo '[4/5] Grafana를 재시작하고 상태를 확인합니다.'
if ! systemctl restart grafana.service; then
  cp -a -- "$DASHBOARD_BACKUP" "$DASHBOARD"
  systemctl restart grafana.service || true
  echo 'ERROR: Grafana 재시작 실패. 대시보드를 복구했습니다.' >&2
  exit 7
fi

for _ in $(seq 1 30); do
  if curl -fsS http://192.168.14.73:3000/api/health >/dev/null; then
    break
  fi
  sleep 1
done
curl -fsS http://192.168.14.73:3000/api/health >/dev/null || {
  cp -a -- "$DASHBOARD_BACKUP" "$DASHBOARD"
  systemctl restart grafana.service || true
  echo 'ERROR: Grafana health 실패. 대시보드를 복구했습니다.' >&2
  exit 8
}

echo '[5/5] 경보와 대시보드 반영 결과를 확인합니다.'
curl -fsS 'http://127.0.0.1:9090/api/v1/rules?type=alert' |
  jq -r '
    .data.groups[].rules[]
    | select(.name == "NeuroplanServiceProbeFailed" or .name == "NeuroplanServiceSlowResponse")
    | [.name,.state,.labels.severity]
    | @tsv
  '

jq -r '
  .panels[]
  | select(.id == 14 or .id == 15 or .id == 16)
  | [.id,.title]
  | @tsv
' "$DASHBOARD" | sort -n

echo 'BLACKBOX_ALERTS_DASHBOARD_READY'
echo "DASHBOARD_BACKUP=$DASHBOARD_BACKUP"
if $RULE_EXISTED; then
  echo "RULE_BACKUP=$RULE_BACKUP"
fi
