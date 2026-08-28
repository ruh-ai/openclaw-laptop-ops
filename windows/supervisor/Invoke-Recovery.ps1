<# Staged recovery. Called by Supervisor.ps1 after CONFIRM_FAILURES consecutive failed cycles. Honors RECOVERY_MODE:
   observe -> log + Slack only.   restart -> steps 1-3.   repair -> steps 1-4 (AI runner inside WSL as WSL_USER).
   Steps: 1 capture evidence  2 restart gateway (systemd)  3 restart WSL distro  4 rollback last-known-good  5 AI repair
   Each step re-checks health and stops at the first success. Returns the step that fixed it or 'failed'. #>
param([Parameter(Mandatory)]$Health, [Parameter(Mandatory)]$State)
Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force
$site = Import-SiteConfig
$mode = $site['RECOVERY_MODE']
function Check { $r = & (Join-Path $PSScriptRoot 'HealthCheck.ps1') -Json | ConvertFrom-Json; return $r.healthy }
function Evidence($tag) {
    $dir = Join-Path $site['OPS_ROOT_WIN'] "reports\incident-$(Get-Date -Format yyyyMMdd-HHmmss)-$tag"; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    ($Health | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $dir 'health.json')
    if (Test-WslRunning) { (Invoke-WslScript -Script 'wsl/snapshot.sh' -Arguments @('--evidence', (ConvertTo-WslPath $dir)) -TimeoutSec 180).Output | Set-Content (Join-Path $dir 'wsl-evidence.txt') }
    (& wsl.exe -l -v 2>&1) -replace "`0", '' | Set-Content (Join-Path $dir 'wsl-list.txt')
    Get-WinEvent -LogName System -MaxEvents 200 -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message | Export-Csv (Join-Path $dir 'system-events.csv') -NoTypeInformation
    return $dir
}
$failing = ($Health.critical -join ', ')
Write-OpsLog -Level ALERT -Component recovery -Message "Confirmed failure: $failing (mode=$mode)"
$ev = Evidence 'confirmed'
Send-OpsSlack -Title 'Failure confirmed' -Text "Failing: $failing" -Severity danger -Fields @{ mode = $mode; evidence = $ev } | Out-Null
if ($mode -eq 'observe') { Write-OpsLog -Component recovery -Message 'RECOVERY_MODE=observe — no action taken'; return 'observe' }

# Step 2: restart gateway service
if ((Test-WslRunning) -and ($Health.critical -contains 'gateway.service' -or $Health.critical -contains 'gateway.rpc' -or $Health.critical -contains 'gateway.port.windows')) {
    Send-OpsSlack -Title 'Recovery step: restart gateway' -Severity warning | Out-Null
    Invoke-WslBash -Command "systemctl --user restart $($site['OPENCLAW_SERVICE']) && sleep 8 && openclaw gateway status --require-rpc" -TimeoutSec 120 | Out-Null
    if (Check) { Send-OpsSlack -Title 'Recovered by gateway restart' -Severity good | Out-Null; return 'restart-gateway' }
}
# Step 3: restart WSL distro (terminate only this distro; the WSLBoot task form keeps it alive)
Send-OpsSlack -Title 'Recovery step: restart WSL distro' -Severity warning | Out-Null
& wsl.exe --terminate $site['DISTRO'] 2>$null | Out-Null; Start-Sleep 5
Start-Process 'wsl.exe' -ArgumentList @('-d', $site['DISTRO'], '--exec', 'dbus-launch', 'true') -WindowStyle Hidden -Wait
Start-Sleep 25
if (Check) { Send-OpsSlack -Title 'Recovered by WSL restart' -Severity good | Out-Null; return 'restart-wsl' }
# Step 4: rollback to last-known-good config snapshot
if ($State.lastKnownGoodSnapshot) {
    Send-OpsSlack -Title 'Recovery step: rollback config' -Text "snapshot $($State.lastKnownGoodSnapshot)" -Severity warning | Out-Null
    $rb = Invoke-WslScript -Script 'wsl/rollback.sh' -Arguments @($State.lastKnownGoodSnapshot) -TimeoutSec 300
    Write-OpsLog -Component recovery -Message "rollback: exit $($rb.ExitCode)"
    if (Check) { Send-OpsSlack -Title 'Recovered by rollback' -Severity good | Out-Null; return 'rollback' }
}
if ($mode -ne 'repair') { Send-OpsSlack -Title 'Recovery FAILED (restart mode; AI repair not enabled)' -Severity danger | Out-Null; return 'failed' }

# Step 5: AI repair — rate limited
$hourAgo = (Get-Date).AddHours(-1)
$recent = @($State.aiRepairs | Where-Object { [datetime]$_.ts -gt $hourAgo })
if ($recent.Count -ge [int]$site['MAX_AI_REPAIRS_PER_HOUR']) {
    Write-OpsLog -Level WARN -Component recovery -Message "AI repair limit reached ($($recent.Count)/h) — cooldown"
    if (-not $State.cooldownUntil -or [datetime]$State.cooldownUntil -lt (Get-Date)) { $State.cooldownUntil = (Get-Date).AddMinutes([int]$site['AI_COOLDOWN_MIN']).ToString('o'); Send-OpsSlack -Title 'AI repair limit reached — cooldown started' -Text "until $($State.cooldownUntil)" -Severity danger | Out-Null }
    return 'cooldown'
}
if ($State.cooldownUntil -and [datetime]$State.cooldownUntil -gt (Get-Date)) { return 'cooldown' }
Send-OpsSlack -Title 'Recovery step: AI repair invoked' -Text "primary=$($site['AI_PRIMARY'])" -Severity warning | Out-Null
$rr = Invoke-WslScript -Script 'wsl/repair/repair-runner.sh' -Arguments @('--evidence', (ConvertTo-WslPath $ev)) -TimeoutSec (60 * [int]$site['AI_REPAIR_TIMEOUT_MIN'] + 120)
$State.aiRepairs = @($State.aiRepairs) + @(@{ ts = (Get-Date).ToString('o'); exit = $rr.ExitCode; evidence = $ev })
Write-OpsLog -Component recovery -Message "AI repair runner exit $($rr.ExitCode)"
($rr.Output) | Set-Content (Join-Path $ev 'ai-repair.log')
if ($rr.ExitCode -eq 0 -and (Check)) { Send-OpsSlack -Title 'Recovered by AI repair' -Text ((Get-Content (Join-Path $ev 'ai-repair.log') -Tail 15) -join "`n") -Severity good | Out-Null; return 'ai-repair' }
Send-OpsSlack -Title 'AI repair FAILED verification — rolled back' -Text ((Get-Content (Join-Path $ev 'ai-repair.log') -Tail 10 -ErrorAction SilentlyContinue) -join "`n") -Severity danger | Out-Null
return 'failed'
