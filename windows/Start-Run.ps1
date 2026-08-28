<# INTAKE - collect everything a human must type, ONCE, before the autonomous run. Run as WIN_USER, elevated.
   Stores (DPAPI, current user) in %OPS_ROOT%\secrets\:  slack (kept), ts-authkey (deleted after Tailscale is up),
   run-cred (WIN_USER password for scheduled tasks; deleted after tasks are registered).
   Also lets you set the few site.env values discovery cannot infer (SITE_NAME, TS_HOSTNAME) so no script has to ask later. #>
param(
    [switch]$SkipSecrets,
    # Non-interactive use (dry runs / automation). Secrets as SecureString; anything omitted is prompted for.
    [string]$SiteName, [string]$TsHostname,
    [securestring]$TsAuthKey, [securestring]$SlackWebhook, [securestring]$WindowsPassword,
    [switch]$NoSlack, [switch]$NoTailscaleKey
)
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Assert-Admin
$root = Get-RepoRoot
$siteEnv = Join-Path $root 'config\site.env'
if (-not (Test-Path $siteEnv)) { Copy-Item (Join-Path $root 'config\site.env.example') $siteEnv }
$site = Import-SiteConfig
Initialize-OpsRoot | Out-Null

function Set-SiteValue($key, $value) {
    $c = Get-Content $siteEnv
    if ($c -match "^$key=") { $c = $c -replace "^($key=)[^#]*", ('${1}' + $value + ' ') } else { $c += "$key=$value" }
    $c | Set-Content $siteEnv -Encoding ascii
}
Write-Host "`n== Intake for openclaw-laptop-ops (all prompts in one go; nothing is echoed or logged) ==" -ForegroundColor Cyan
# WIN_USER = the account running this (tasks + DPAPI must be this account)
Set-SiteValue 'WIN_USER' $env:USERNAME
Write-Host "WIN_USER = $env:USERNAME (this account owns the WSL distro? if not, re-run Start-Run.ps1 as the owner)"
$nonInteractive = $PSBoundParameters.Count -gt 0 -and -not $SkipSecrets
if ($SiteName) { Set-SiteValue 'SITE_NAME' $SiteName } ; if ($TsHostname) { Set-SiteValue 'TS_HOSTNAME' $TsHostname }
if (-not $SiteName -or -not $TsHostname) {
    foreach ($k in 'SITE_NAME', 'TS_HOSTNAME') {
        if (($k -eq 'SITE_NAME' -and $SiteName) -or ($k -eq 'TS_HOSTNAME' -and $TsHostname)) { continue }
        $cur = $site[$k]
        $v = Read-Host "$k [$cur]"
        if ($v) { Set-SiteValue $k $v }
    }
}
if (-not $SkipSecrets) {
    if ($TsAuthKey) { Set-OpsSecret -Name 'ts-authkey' -Value $TsAuthKey }
    elseif (-not $NoTailscaleKey) {
        Write-Host "`nTailscale auth key (tskey-auth-..., pre-approved, tagged). Enter = skip and log in via browser later:" -ForegroundColor Yellow
        $ts = Read-Host -AsSecureString
        if ($ts.Length -gt 0) { Set-OpsSecret -Name 'ts-authkey' -Value $ts }
    }
    $sl = $null
    if ($SlackWebhook) { $sl = $SlackWebhook }
    elseif (-not $NoSlack) { Write-Host "Slack incoming webhook URL (https://hooks.slack.com/services/...). Enter = skip:" -ForegroundColor Yellow; $sl = Read-Host -AsSecureString; if ($sl.Length -eq 0) { $sl = $null } }
    if ($sl) { Set-OpsSecret -Name 'slack' -Value $sl; if (Send-OpsSlack -Title 'Intake complete' -Text 'Autonomous run starting.' -Severity info) { Write-Host '  Slack test OK' -ForegroundColor Green } else { Write-Host '  Slack test failed (queued) - check URL/network' -ForegroundColor Yellow } }
    if ($WindowsPassword) { Set-OpsSecret -Name 'run-cred' -Value $WindowsPassword }
    else {
        Write-Host "Windows password for $env:USERNAME (needed once so scheduled tasks run before login; deleted after task registration):" -ForegroundColor Yellow
        $pw = Read-Host -AsSecureString
        if ($pw.Length -gt 0) { Set-OpsSecret -Name 'run-cred' -Value $pw }
    }
}
$s = Get-OpsState; $s.intakeDone = (Get-Date).ToString('o'); Set-OpsState $s
Write-OpsLog -Component intake -Message 'intake complete'
Write-Host "`nIntake done. Now run:  .\windows\Run-All.ps1        (or let the agent do it)" -ForegroundColor Green
