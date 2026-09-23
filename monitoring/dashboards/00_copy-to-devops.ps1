[CmdletBinding()]
param(
    [string]$DevOpsHost = "192.168.14.21",
    [string]$DevOpsUser = "devops"
)

$ErrorActionPreference = "Stop"
$Source = $PSScriptRoot
$Target = "${DevOpsUser}@${DevOpsHost}:/home/devops/monitoring/"

Write-Host "전송 원본: $Source"
Write-Host "전송 대상: $Target"

scp -r -- $Source $Target
if ($LASTEXITCODE -ne 0) {
    throw "SCP 전송에 실패했습니다."
}

Write-Host "전송 완료: /home/devops/monitoring/grafana-dashboards-v2"
Write-Host "다음 단계: DevOps VM에서 07_apply-dashboards.sh를 실행하세요."
