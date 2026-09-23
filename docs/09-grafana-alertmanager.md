# Grafana와 Alertmanager

Grafana 대시보드는 다음 영역으로 구분합니다.

- 전체 인프라 요약
- DB·스토리지
- Main Kubernetes
- DR K3s
- 모니터링
- NeuroPlan 서비스
- 로그 조사

Provisioning 가능한 대시보드 YAML은 [monitoring/dashboards](../monitoring/dashboards/)에 있습니다.

Prometheus는 Alert Rule을 평가하고 Alertmanager는 장애 발생·복구 메일을 Gmail로 발송합니다. 현재 Alert Rule은 [06_infraready_alerts.yml](../monitoring/external/06_infraready_alerts.yml)에 있습니다.

Gmail 앱 비밀번호는 `/etc/alertmanager/secrets/gmail-app-password`에 `0600` 권한으로 저장하며 Git에 포함하지 않습니다.

