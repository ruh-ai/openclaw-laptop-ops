<# The Windows supervisor - one cycle per scheduled-task fire (every SUPERVISOR_INTERVAL_MIN, and at boot).
   - lock (single instance) - health check - state counters - boot detection & availability-gap report
   - staged recovery via Invoke-Recovery.ps1 after CONFIRM_FAILURES fails (respecting RECOVERY_MODE)
   - Slack on STATE CHANGES only; daily summary at 09:00
   Flags for tests: -TestSlack (send a test message and exit), -ClearCooldown, -Once (default; it always runs once) #>
param([switch]$TestSlack, [switch]$ClearCooldown, [switch]$Deep)
Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force
$site = Import-SiteConfig
Initialize-OpsRoot | Out-Null
if ($TestSlack) { $ok = Send-OpsSlack -Title 'Supervisor test message' -Severity info; exit $(if ($ok) { 0 } else { 1 }) }
if (-not (Enter-OpsLock -Name supervisor -StaleMinutes 30)) { Write-OpsLog -Level DEBUG -Component supervisor -Message 'another cycle is running - skip'; exit 0 }
try {
    $state = Get-OpsState
    if ($ClearCooldown) { $state.cooldownUntil = $null; $state.aiRepairs = @(); Set-OpsState $state; Write-OpsLog -Component supervisor -Message 'cooldown cleared'; exit 0 }
    $state.recoveryMode = $site['RECOVERY_MODE']
    # Boot detection + availability gap
    $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $bootId = $bootTime.ToString('o')
    if ($state.lastBootId -ne $bootId) {
        $gap = if ($state.lastHeartbeat) { [math]::Round(((Get-Date) - [datetime]$state.lastHeartbeat).TotalMinutes) } else { $null }
        Write-OpsLog -Level WARN -Component supervisor -Message "New boot detected ($bootId); previous heartbeat gap: $gap min"
        if ($gap -and $gap -gt [int]$site['HEARTBEAT_GAP_ALERT_MIN']) { Send-OpsSlack -Title 'Windows restarted - availability gap detected' -Text "Last heartbeat $gap min before this check. Boot at $($bootTime.ToString('u'))." -Severity warning | Out-Null }
        $state.lastBootId = $bootId; $state.bootReported = $false
    }
    # Deep every 5th minute; light otherwise
    $deep = $Deep -or ((Get-Date).Minute % 5 -eq 0)
    $health = & (Join-Path $PSScriptRoot 'HealthCheck.ps1') -Json -Deep:$deep | ConvertFrom-Json
    $state.lastCheck = $health.ts; $state.lastHeartbeat = $health.ts
    $prev = $state.status
    if ($health.healthy) {
        $state.consecutiveHealthy = [int]$state.consecutiveHealthy + 1; $state.consecutiveFailures = 0; $state.lastHealthy = $health.ts
        if ($prev -in 'failed', 'recovering' -and $state.consecutiveHealthy -ge [int]$site['STABILIZATION_CYCLES']) {
            $state.status = 'healthy'; Send-OpsSlack -Title 'Recovery succeeded - stable' -Text "$($site['STABILIZATION_CYCLES']) consecutive healthy cycles (via $($state.recoveryStep))" -Severity good | Out-Null
            $state.recoveryStep = 'none'
            # promote current config to last-known-good
            if (Test-WslRunning) { $snap = Invoke-WslScript -Script 'wsl/snapshot.sh' -Arguments @('--mark-good') -TimeoutSec 180; if ($snap.ExitCode -eq 0) { $state.lastKnownGoodSnapshot = ($snap.Output -split "`n" | Select-Object -Last 1).Trim() } }
        } elseif ($prev -notin 'healthy', 'recovering', 'failed') { $state.status = 'healthy' }
        if (-not $state.bootReported -and $state.status -eq 'healthy') { Send-OpsSlack -Title 'System available' -Text "All checks green after boot. Mode: $($site['RECOVERY_MODE'])." -Severity good | Out-Null; $state.bootReported = $true }
        if ($prev -eq 'failed' -and $state.status -eq 'failed') { $state.status = 'recovering' }
        # daily LKG snapshot at 04:00 when healthy for a while
        if ((Get-Date).Hour -eq 4 -and (Get-Date).Minute -lt [int]$site['SUPERVISOR_INTERVAL_MIN'] -and (Test-WslRunning)) { $snap = Invoke-WslScript -Script 'wsl/snapshot.sh' -Arguments @('--mark-good') -TimeoutSec 180; if ($snap.ExitCode -eq 0) { $state.lastKnownGoodSnapshot = ($snap.Output -split "`n" | Select-Object -Last 1).Trim() } }
    } else {
        $state.consecutiveFailures = [int]$state.consecutiveFailures + 1; $state.consecutiveHealthy = 0
        Write-OpsLog -Level WARN -Component supervisor -Message "Unhealthy ($($state.consecutiveFailures)/$($site['CONFIRM_FAILURES'])): $($health.critical -join ', ')"
        if ($state.consecutiveFailures -ge [int]$site['CONFIRM_FAILURES'] -and $state.status -ne 'failed') {
            $state.status = 'failed'
            $state.incidents = @($state.incidents) + @(@{ ts = $health.ts; failing = $health.critical })
            $step = & (Join-Path $PSScriptRoot 'Invoke-Recovery.ps1') -Health $health -State $state
            $state.recoveryStep = "$step"
            if ($step -notin 'observe', 'failed', 'cooldown') { $state.status = 'recovering' }
        }
    }
    # Warnings (disk, internet, slack, teamviewer) - report once per day per warning
    foreach ($w in $health.warnings) {
        $key = "warn:$w"; $last = if ($state.Contains($key)) { $state[$key] } else { $null }
        if (-not $last -or ([datetime]$last -lt (Get-Date).AddHours(-24))) { Send-OpsSlack -Title "Warning: $w" -Text $health.checks.$w.detail -Severity warning | Out-Null; $state[$key] = (Get-Date).ToString('o') }
    }
    # Daily summary 09:00
    if ((Get-Date).Hour -eq 9 -and (Get-Date).Minute -lt [int]$site['SUPERVISOR_INTERVAL_MIN']) {
        $inc = @($state.incidents | Where-Object { [datetime]$_.ts -gt (Get-Date).AddDays(-1) }).Count
        Send-OpsSlack -Title 'Daily health summary' -Severity info -Fields @{ status = $state.status; incidents24h = $inc; mode = $site['RECOVERY_MODE']; lastKnownGood = "$($state.lastKnownGoodSnapshot)"; disk = "$($health.checks.'windows.disk'.detail) / WSL $($health.checks.'wsl.disk'.detail)" } | Out-Null
    }
    Set-OpsState $state
    Flush-OpsSlackQueue
    Write-OpsLog -Level DEBUG -Component supervisor -Message "cycle done: status=$($state.status) healthy=$($health.healthy)"
} finally { Exit-OpsLock -Name supervisor }
