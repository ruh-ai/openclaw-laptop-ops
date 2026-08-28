<# Returns a structured health object (also dot-sourced by Supervisor and 90-verify). Read-only.
   Usage: .\windows\supervisor\HealthCheck.ps1 [-Json] [-Deep]   (-Deep adds TS_URL probe + disk + AI auth) #>
param([switch]$Json, [switch]$Deep)
Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force
$site = Import-SiteConfig
function Get-Health {
    param([switch]$Deep)
    $h = [ordered]@{ ts = (Get-Date).ToString('o'); checks = [ordered]@{}; healthy = $true; critical = @(); warnings = @() }
    function Add($name, $ok, $detail, [switch]$Warn) { $h.checks[$name] = [ordered]@{ ok = [bool]$ok; detail = "$detail" }; if (-not $ok) { if ($Warn) { $h.warnings += $name } else { $h.critical += $name; $h.healthy = $false } } }

    $ts = Get-TailscaleExe
    $tsSvc = Get-Service Tailscale -ErrorAction SilentlyContinue
    Add 'tailscale.service' ($tsSvc -and $tsSvc.Status -eq 'Running') "$(if($tsSvc){$tsSvc.Status}else{'missing'})"
    $st = if ($ts) { (& $ts status --json 2>$null) | Out-String } else { '' }
    Add 'tailscale.backend' ($st -match '"BackendState":\s*"Running"') $(if ($st -match '"BackendState":\s*"([^"]+)"') { $Matches[1] } else { 'n/a' })
    $ssh = Get-Service sshd -ErrorAction SilentlyContinue
    Add 'sshd' ($ssh -and $ssh.Status -eq 'Running') "$(if($ssh){$ssh.Status}else{'missing'})"
    Add 'teamviewer' ((Get-Service TeamViewer -ErrorAction SilentlyContinue).Status -eq 'Running') 'fallback access path' -Warn

    $running = Test-WslRunning
    Add 'wsl.running' $running "distro $($site['DISTRO']) $(if($running){'running'}else{'NOT running (idle-terminated or failed)'})"
    if ($running) {
        $r = Invoke-WslScript -Script 'wsl/healthcheck.sh' -Arguments @('--json') -TimeoutSec 90
        $inner = $null; try { $inner = ($r.Output -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1) | ConvertFrom-Json } catch {}
        if ($inner) {
            Add 'wsl.systemd' $inner.systemd "pid1=$($inner.pid1)"
            Add 'gateway.service' $inner.service_active "$($inner.service_state)"
            Add 'gateway.rpc' $inner.rpc_ok "gateway status --require-rpc: $($inner.rpc_detail)"
            Add 'wsl.disk' ($inner.disk_used_pct -lt [int]$site['DISK_WARN_PCT']) "$($inner.disk_used_pct)% used" -Warn
            $h.wslIp = $inner.wsl_ip
        } else { Add 'wsl.healthcheck' $false "healthcheck.sh unparseable (exit $($r.ExitCode)): $($r.Output.Substring(0,[Math]::Min(300,$r.Output.Length)))" }
    } else { foreach ($n in 'wsl.systemd', 'gateway.service', 'gateway.rpc') { Add $n $false 'WSL not running' } }

    Add 'gateway.port.windows' (Test-TcpPort -Port ([int]$site['GATEWAY_PORT'])) "127.0.0.1:$($site['GATEWAY_PORT']) from Windows"
    if ($Deep) {
        Add 'gateway.http.local' (Test-HttpOk -Url "$($site['LOCAL_GATEWAY_URL'])/") 'UI over localhost'
        if ($site['TS_URL']) {
            $serve = if ($ts) { (& $ts serve status 2>$null) | Out-String } else { '' }
            Add 'tailscale.serve' ($serve -match [regex]::Escape($site['LOCAL_GATEWAY_URL'])) $(if ($serve) { ($serve -split "`n")[0] } else { 'no serve config' })
            Add 'gateway.http.tailnet' (Test-HttpOk -Url "$($site['TS_URL'])/") $site['TS_URL']
        }
        $c = Get-PSDrive C; $pct = [math]::Round(100 * $c.Used / ($c.Used + $c.Free))
        Add 'windows.disk' ($pct -lt [int]$site['DISK_WARN_PCT']) "C: $pct% used, $([math]::Round($c.Free/1GB,1)) GB free" -Warn
        Add 'internet' (Test-HttpOk -Url 'https://www.msftconnecttest.com/connecttest.txt' -TimeoutSec 6) 'outbound HTTPS' -Warn
        Add 'slack.secret' ([bool](Get-OpsSecret -Name slack)) 'webhook stored (DPAPI)' -Warn
        Add 'reboot.pending' (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) 'Windows Update reboot pending?' -Warn
        if ($running -and $site['RECOVERY_MODE'] -eq 'repair') {
            $ai = Invoke-WslScript -Script 'wsl/repair/verify.sh' -Arguments @('--ai-auth') -TimeoutSec 120
            Add 'ai.auth' ($ai.ExitCode -eq 0) ($ai.Output -split "`n" | Select-Object -Last 1) -Warn
        }
    }
    return $h
}
$health = Get-Health -Deep:$Deep
if ($Json) { $health | ConvertTo-Json -Depth 6 } else {
    foreach ($k in $health.checks.Keys) { $c = $health.checks[$k]; $mark = if ($c.ok) { 'OK  ' } elseif ($k -in $health.warnings) { 'WARN' } else { 'FAIL' }; Write-Host ("{0} {1,-24} {2}" -f $mark, $k, $c.detail) -ForegroundColor $(if ($c.ok) { 'Green' } elseif ($mark -eq 'WARN') { 'Yellow' } else { 'Red' }) }
    Write-Host ("HEALTHY: {0}" -f $health.healthy) -ForegroundColor $(if ($health.healthy) { 'Green' } else { 'Red' })
}
if (-not $health.healthy) { exit 1 }
