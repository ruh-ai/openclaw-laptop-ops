<# Store a secret with DPAPI (current user). MUST be run as WIN_USER - the account the scheduled tasks run as.
   Usage: .\windows\secrets\Set-OpsSecret.ps1 -Name slack        (prompts; paste the Slack incoming-webhook URL)
   Names in use: slack  #>
param([Parameter(Mandatory)][ValidateSet('slack')][string]$Name)
Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force
$site = Import-SiteConfig
if ($site['WIN_USER'] -and $env:USERNAME -ne $site['WIN_USER']) {
    throw "You are '$env:USERNAME' but WIN_USER is '$($site['WIN_USER'])'. DPAPI secrets must be written by the task account. Re-run as $($site['WIN_USER'])."
}
Initialize-OpsRoot | Out-Null
Write-Host "[HUMAN AT CONSOLE] Paste the value for secret '$Name' (input hidden), then Enter:" -ForegroundColor Cyan
$v = Read-Host -AsSecureString
Set-OpsSecret -Name $Name -Value $v
if ($Name -eq 'slack') {
    Write-Host 'Sending a test message...'
    if (Send-OpsSlack -Title 'Slack webhook configured' -Text 'openclaw-laptop-ops can now report here.' -Severity good) { Write-Host 'OK' -ForegroundColor Green } else { Write-Host 'Send failed - check the URL and network; message queued.' -ForegroundColor Yellow }
}
