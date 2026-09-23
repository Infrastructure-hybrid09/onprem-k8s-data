[CmdletBinding()]
param(
    [string]$MonitoringHost = "192.168.14.73",
    [string]$MonitoringUser = "ansible"
)

$ErrorActionPreference = "Stop"
$Source = Join-Path $PSScriptRoot "27_update_mariadb_disk_panel.sh"
$Target = "${MonitoringUser}@${MonitoringHost}:/home/${MonitoringUser}/"

if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
    throw "scp를 찾을 수 없습니다. Windows OpenSSH Client를 설치하세요."
}

Write-Host "전송 원본: $Source"
Write-Host "전송 대상: $Target"

& scp -- $Source $Target
if ($LASTEXITCODE -ne 0) {
    throw "Monitoring VM 전송에 실패했습니다. exit code=$LASTEXITCODE"
}

Write-Host "전송 완료: /home/${MonitoringUser}/27_update_mariadb_disk_panel.sh"
Write-Host "다음 명령을 Monitoring VM에서 실행하세요:"
Write-Host "  cd /home/${MonitoringUser}"
Write-Host "  chmod 750 27_update_mariadb_disk_panel.sh"
Write-Host "  sudo ./27_update_mariadb_disk_panel.sh"
