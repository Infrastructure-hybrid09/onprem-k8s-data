[CmdletBinding()]
param(
    [string]$DevOpsHost = "192.168.14.21",
    [string]$DevOpsUser = "devops"
)

$ErrorActionPreference = "Stop"
$Source = $PSScriptRoot
$Target = "${DevOpsUser}@${DevOpsHost}:/home/devops/monitoring/"

if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
    throw "scp was not found. Install the Windows OpenSSH Client first."
}

Write-Host "전송 원본: $Source"
Write-Host "전송 대상: $Target"

& scp -r -- $Source $Target
if ($LASTEXITCODE -ne 0) {
    throw "SCP 전송에 실패했습니다. exit code=$LASTEXITCODE"
}

Write-Host "전송 완료: /home/devops/monitoring/external-monitoring-pc6"
Write-Host "다음 단계:"
Write-Host "  ssh ${DevOpsUser}@${DevOpsHost}"
Write-Host "  cd /home/devops/monitoring/external-monitoring-pc6"
Write-Host "  chmod 750 ./*.sh"
Write-Host "  ./00_collect-current-state.sh"
