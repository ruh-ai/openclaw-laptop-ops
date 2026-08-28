<# Phase gates. Exit 0 = PASS. Prints every check. -Watch repeats every 30s until Ctrl+C (for reboot tests from a second device).
   Phase 1: Tailscale Running + sshd listening + firewall scoped + (human-confirmed) remote SSH   -ConfirmRemoteSsh to record the human's confirmation
   Phase 2: WSL running, PID1 systemd, gateway service active, RPC ok, localhost forwarding
   Phase 3: Serve configured, TS_URL responds, allowedOrigins set, (human-confirmed) UI pairs from second device  -ConfirmUiPaired
   Phase 4: tasks registered, supervisor ran within 3 min, Slack secret present, first backup + export exist, power settings
   Phase 5 (later): RECOVERY_MODE restart/repair prerequisites. #>
param([Parameter(Mandatory)][ValidateRange(0, 5)][int]$Phase, [switch]$Watch, [switch]$ConfirmRemoteSsh, [switch]$ConfirmUiPaired)
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$site = Import-SiteConfig; Initialize-OpsRoot | Out-Null
$state = Get-OpsState
if ($ConfirmRemoteSsh) { $state.humanConfirmedRemoteSsh = (Get-Date).ToString('o'); Set-OpsState $state }
if ($ConfirmUiPaired) { $state.humanConfirmedUiPaired = (Get-Date).ToString('o'); Set-OpsState $state }
function Run-Gate {
    $res = New-Object System.Collections.Generic.List[object]
    function G($name, $ok, $detail) { $res.Add([pscustomobject]@{ check = $name; ok = [bool]$ok; detail = "$detail" }) }
    $h = & (Join-Path $PSScriptRoot 'supervisor\HealthCheck.ps1') -Json -Deep | ConvertFrom-Json
    function HC($n) { $c = $h.checks.$n; if ($c) { G $n $c.ok $c.detail } else { G $n $false 'no data' } }
    if ($Phase -ge 1) {
        HC 'tailscale.service'; HC 'tailscale.backend'; HC 'sshd'
        $fw = Get-NetFirewallRule -Name 'OpenClawOps-SSH-Tailnet' -ErrorAction SilentlyContinue; G 'firewall.ssh.tailnet-only' ($fw -and $fw.Enabled -eq 'True' -and (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue).Enabled -ne 'True') 'OpenClawOps-SSH-Tailnet on, stock rule off'
        G 'ssh.reachable' ([bool]$state.humanConfirmedRemoteSsh -or [bool]$state.autoVerifiedSelfSsh) "$(if($state.humanConfirmedRemoteSsh){"remote, human-confirmed $($state.humanConfirmedRemoteSsh)"}elseif($state.autoVerifiedSelfSsh){"self-SSH over tailnet IP auto-verified $($state.autoVerifiedSelfSsh); remote check is on the post-run list"}else{'run Run-All.ps1 (auto) or 90-verify.ps1 -Phase 1 -ConfirmRemoteSsh after ssh from a 2nd device'})"
        HC 'teamviewer'
    }
    if ($Phase -ge 2) { HC 'wsl.running'; HC 'wsl.systemd'; HC 'gateway.service'; HC 'gateway.rpc'; HC 'gateway.port.windows'
        $lin = Invoke-WslBash -Command "loginctl show-user '$($site['WSL_USER'])' -p Linger --value" -AsRoot; G 'wsl.linger' ($lin.Output -match 'yes') $lin.Output.Trim()
        $tok = Invoke-WslBash -Command "grep -q '^OPENCLAW_GATEWAY_TOKEN=' '$($site['OPENCLAW_HOME'])/.env' && stat -c %a '$($site['OPENCLAW_HOME'])/.env'"; G 'gateway.token.in-env-600' ($tok.Output.Trim() -eq '600') "mode $($tok.Output.Trim())" }
    if ($Phase -ge 3) { HC 'tailscale.serve'; HC 'gateway.http.tailnet'
        $cfg = Invoke-WslBash -Command "openclaw config get gateway.controlUi.allowedOrigins 2>/dev/null || grep -o 'allowedOrigins[^]]*]' '$($site['OPENCLAW_HOME'])/openclaw.json'"; G 'gateway.allowedOrigins' ($cfg.Output -match [regex]::Escape($site['TS_URL'])) $cfg.Output.Trim()
        G 'ui.reachable' ([bool]$state.humanConfirmedUiPaired -or [bool]$state.autoVerifiedUiHttp) "$(if($state.humanConfirmedUiPaired){"paired, human-confirmed $($state.humanConfirmedUiPaired)"}elseif($state.autoVerifiedUiHttp){"TS_URL HTTP auto-verified $($state.autoVerifiedUiHttp); pairing is on the post-run list"}else{'run Run-All.ps1 (auto) or 90-verify.ps1 -Phase 3 -ConfirmUiPaired after the Control UI pairs from a 2nd device'})" }
    if ($Phase -ge 4) {
        foreach ($n in 'OpenClawOps-WSLBoot', 'OpenClawOps-Supervisor', 'OpenClawOps-BackupNightly', 'OpenClawOps-WslExportWeekly') { $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue; G "task.$n" ($t -and $t.State -ne 'Disabled' -and $t.Principal.UserId -like "*$($site['WIN_USER'])") "$(if($t){"$($t.State) as $($t.Principal.UserId)"}else{'missing'})" }
        $lc = if ($state.lastCheck) { ((Get-Date) - [datetime]$state.lastCheck).TotalMinutes } else { 9999 }; G 'supervisor.recent' ($lc -lt 3) "last cycle $([math]::Round($lc,1)) min ago"
        HC 'slack.secret'
        $d = Get-ChildItem (Join-Path $site['OPS_ROOT_WIN'] 'backups\daily') -Filter '*.tar.gz' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; G 'backup.daily.exists' ([bool]$d) "$(if($d){$d.Name}else{'run windows\backup\Backup-OpenClaw.ps1'})"
        $e = Get-ChildItem (Join-Path $site['OPS_ROOT_WIN'] 'backups\wsl-export') -Filter '*.tar' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; G 'backup.wsl-export.exists' ([bool]$e) "$(if($e){"$($e.Name) $([math]::Round($e.Length/1GB,2)) GB"}else{'run windows\backup\Export-Wsl.ps1'})"
        $sb = (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String 'AC Power Setting Index: 0x00000000'); G 'power.no-sleep-on-ac' ([bool]$sb) 'standby-timeout-ac = 0'
        G 'recovery.mode' ($site['RECOVERY_MODE'] -eq 'observe') "RECOVERY_MODE=$($site['RECOVERY_MODE']) (tonight must be observe)"
    }
    if ($Phase -ge 5) {
        $s = $state; G 'observe.24h' ($s.lastHealthy -and $s.incidents.Count -eq 0) 'no incidents recorded in observe (manual: check logs for 24h)'
        G 'lkg.snapshot' ([bool]$s.lastKnownGoodSnapshot) "$($s.lastKnownGoodSnapshot)"
        $ai = Invoke-WslScript -Script 'wsl/repair/verify.sh' -Arguments @('--ai-auth') -TimeoutSec 120; G 'ai.auth' ($ai.ExitCode -eq 0) ($ai.Output -split "`n" | Select-Object -Last 1)
    }
    return $res
}
do {
    $res = Run-Gate
    Clear-Host; Write-Host "Gate check - Phase $Phase - $(Get-Date -Format u)" -ForegroundColor Cyan
    foreach ($r in $res) { Write-Host ("{0} {1,-34} {2}" -f $(if ($r.ok) { 'PASS' } else { 'FAIL' }), $r.check, $r.detail) -ForegroundColor $(if ($r.ok) { 'Green' } else { 'Red' }) }
    $pass = -not ($res | Where-Object { -not $_.ok })
    Write-Host ("`nPHASE $Phase {0}" -f $(if ($pass) { 'PASS' } else { 'FAIL' })) -ForegroundColor $(if ($pass) { 'Green' } else { 'Red' })
    if ($pass) { $s = Get-OpsState; if ([int]$s.phase -lt $Phase) { $s.phase = $Phase; Set-OpsState $s }; Write-OpsLog -Component gate -Message "Phase $Phase PASS" }
    if ($Watch) { Start-Sleep 30 }
} while ($Watch)
exit $(if ($pass) { 0 } else { 1 })
