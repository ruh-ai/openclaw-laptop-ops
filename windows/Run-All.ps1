<# ORCHESTRATOR - runs Phases 0-4 straight through using the secrets from Start-Run.ps1. Stops only on a hard failure.
   Replaces the mid-run second-device checks with laptop-side auto-verification:
     - SSH: connects to ITSELF over its own tailnet IP with a throwaway key (exercises sshd + the tailnet-only firewall rule)
     - UI : HTTP probe of TS_URL from this machine (Serve + cert + gateway reachable)
   The real remote checks (ssh from your laptop, pair the UI) move to the POST-RUN checklist it prints; they don't block.
   Usage: .\windows\Run-All.ps1 [-From 0] [-To 4] [-Reboot] [-KeepPassword]
   -Reboot : after Phase 4 passes, restart Windows (10s countdown). The supervisor posts "System available" to Slack after boot. #>
param([ValidateRange(0, 4)][int]$From = 0, [ValidateRange(0, 4)][int]$To = 4, [switch]$Reboot, [switch]$KeepPassword)
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Assert-Admin
$ErrorActionPreference = 'Stop'
$site = Import-SiteConfig; Initialize-OpsRoot | Out-Null
$W = $PSScriptRoot
function Step($n, $cmd) { Write-Host "`n>>> [$n] $cmd" -ForegroundColor Cyan; Write-OpsLog -Component runall -Message "step $n : $cmd" }
function Gate($phase) {
    $out = & (Join-Path $W '90-verify.ps1') -Phase $phase 2>&1 | Out-String
    Write-Host $out
    if ($LASTEXITCODE -ne 0) { Write-OpsLog -Level ERROR -Component runall -Message "Gate $phase FAILED"; Send-OpsSlack -Title "Setup stopped at Phase $phase gate" -Text (($out -split "`n" | Where-Object { $_ -match '^FAIL' }) -join "`n") -Severity danger | Out-Null; throw "Phase $phase gate failed - see FAIL lines above and RUNBOOK 'If something goes wrong'. Fix, then: .\windows\Run-All.ps1 -From $phase" }
    Write-OpsLog -Component runall -Message "Gate $phase PASS"
}
function Invoke-Phase($file) { $p = Join-Path $W $file; & $p; if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "$file exited $LASTEXITCODE" } }

if (-not (Get-OpsState).intakeDone) { throw 'Run .\windows\Start-Run.ps1 first (one-time intake of secrets and names).' }
if ($From -le 0 -and $To -ge 0) {
    Step 0 '00-discovery.ps1 -WriteSiteEnv'; & (Join-Path $W '00-discovery.ps1') -WriteSiteEnv
    $site = Import-SiteConfig
    if (-not $site['DISTRO'] -or -not $site['WIN_USER']) { throw 'Discovery could not determine DISTRO/WIN_USER - edit config\site.env and re-run -From 0' }
    $lv = (& wsl.exe -l -v 2>&1) -replace "`0", '' | Out-String
    if ($lv -notmatch [regex]::Escape($site['DISTRO'])) { throw "DISTRO '$($site['DISTRO'])' not in wsl -l -v output; fix config\site.env" }
    Step 0 'safety snapshot: Export-Wsl.ps1'; & (Join-Path $W 'backup\Export-Wsl.ps1'); if ($LASTEXITCODE -eq 1) { throw 'safety WSL export failed' }
}
if ($From -le 1 -and $To -ge 1) {
    Step 1 '10-tailscale.ps1'; Invoke-Phase '10-tailscale.ps1'; $site = Import-SiteConfig
    Step 1 '11-openssh.ps1 (password auth still on)'; Invoke-Phase '11-openssh.ps1'
    Step 1 'self-SSH over tailnet IP'
    $tsExe = Get-TailscaleExe; $ip = (& $tsExe ip -4 | Select-Object -First 1).Trim()
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $ssh) { Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' | Out-Null }
    $key = Join-Path $env:TEMP "opsself-$PID"; & ssh-keygen -q -t ed25519 -N '""' -f $key | Out-Null
    $pub = Get-Content "$key.pub"
    $isAdmin = [bool](Get-LocalGroupMember -Group Administrators -Member $site['WIN_USER'] -ErrorAction SilentlyContinue)
    $ak = if ($isAdmin) { Join-Path $env:ProgramData 'ssh\administrators_authorized_keys' } else { Join-Path $env:USERPROFILE '.ssh\authorized_keys' }
    Add-Content $ak $pub; if ($isAdmin) { & icacls.exe $ak /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null }
    $res = & ssh.exe -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=10 -i $key "$($site['WIN_USER'])@$ip" 'Write-Output OPS_SELF_OK' 2>&1
    (Get-Content $ak) | Where-Object { $_ -ne $pub } | Set-Content $ak -Encoding ascii; Remove-Item $key, "$key.pub" -Force -ErrorAction SilentlyContinue
    if ("$res" -match 'OPS_SELF_OK') {
        Write-OpsLog -Component runall -Message "self-SSH over $ip OK"; $s = Get-OpsState; $s.autoVerifiedSelfSsh = (Get-Date).ToString('o'); Set-OpsState $s
        Step 1 '11-openssh.ps1 -DisablePassword'; & (Join-Path $W '11-openssh.ps1') -DisablePassword
    } else { throw "self-SSH over tailnet IP $ip failed: $res  (sshd/firewall/keys). Fix and re-run -From 1" }
    Gate 1
}
if ($From -le 2 -and $To -ge 2) {
    Step 2 '20-wsl-prepare.ps1'; Invoke-Phase '20-wsl-prepare.ps1'
    Step 2 '21-wsl-openclaw.ps1'; Invoke-Phase '21-wsl-openclaw.ps1'
    Gate 2
}
if ($From -le 3 -and $To -ge 3) {
    Step 3 '12-tailscale-serve.ps1'; Invoke-Phase '12-tailscale-serve.ps1'; $site = Import-SiteConfig
    $ok = $false; for ($i = 0; $i -lt 12 -and -not $ok; $i++) { if ($site['TS_URL'] -and (Test-HttpOk -Url "$($site['TS_URL'])/")) { $ok = $true } else { Start-Sleep 10 } }
    if ($ok) { $s = Get-OpsState; $s.autoVerifiedUiHttp = (Get-Date).ToString('o'); Set-OpsState $s; Write-OpsLog -Component runall -Message "TS_URL responds: $($site['TS_URL'])" }
    else { throw "TS_URL $($site['TS_URL']) not responding after 2 min (cert issuance? HTTPS not enabled in admin console?). Re-run -From 3" }
    # trustedProxies: try to learn the proxied source address from the journal after our own probe
    $j = Invoke-WslBash -Command "journalctl --user -u $($site['OPENCLAW_SERVICE']) -n 200 --no-pager 2>/dev/null | grep -iE 'proxy|forwarded|origin' | tail -5"
    if ($j.Output -match '(\d{1,3}\.){3}\d{1,3}') { $peer = $Matches[0]; if ($peer -ne '127.0.0.1') { Write-OpsLog -Component runall -Message "gateway saw proxied peer $peer - setting trustedProxies"; & (Join-Path $W '21-wsl-openclaw.ps1') -SkipInstall -ProxySource $peer } }
    Gate 3
}
if ($From -le 4 -and $To -ge 4) {
    Step 4 '40-power.ps1'; Invoke-Phase '40-power.ps1'
    Step 4 '30-startup-task.ps1'; Invoke-Phase '30-startup-task.ps1'
    if (-not $KeepPassword) { Remove-Item (Join-Path $site['OPS_ROOT_WIN'] 'secrets\run-cred.xml') -Force -ErrorAction SilentlyContinue }
    Step 4 'Backup-OpenClaw.ps1'; & (Join-Path $W 'backup\Backup-OpenClaw.ps1'); if ($LASTEXITCODE -eq 1) { throw 'first backup failed' }
    if (-not (Get-ChildItem (Join-Path $site['OPS_ROOT_WIN'] 'backups\wsl-export') -Filter *.tar -ErrorAction SilentlyContinue)) { Step 4 'Export-Wsl.ps1'; & (Join-Path $W 'backup\Export-Wsl.ps1') }
    Step 4 'restore test: snapshot --mark-good + rollback last-known-good'
    $snap = Invoke-WslScript -Script 'wsl/snapshot.sh' -Arguments @('--mark-good'); if ($snap.ExitCode -ne 0) { throw "snapshot failed: $($snap.Output)" }
    $rb = Invoke-WslScript -Script 'wsl/rollback.sh' -Arguments @('last-known-good'); if ($rb.ExitCode -ne 0) { throw "rollback test failed: $($rb.Output)" }
    $s = Get-OpsState; $s.lastKnownGoodSnapshot = ($snap.Output -split "`n" | Select-Object -Last 1).Trim(); Set-OpsState $s
    Gate 4
    Send-OpsSlack -Title 'Setup complete (Phases 0-4)' -Text "Mode: observe. Reboot test: $(if ($Reboot) { 'starting now' } else { 'pending (human)' })" -Severity good | Out-Null
}
Write-Host @"

================ POST-RUN CHECKLIST (do these from YOUR machine; none of them block the laptop) ================
1. ssh $($site['WIN_USER'])@$($site['TS_HOSTNAME'])          -> PowerShell prompt, then:  wsl -d $($site['DISTRO']) -- openclaw gateway status --require-rpc
2. Open $($site['TS_URL'])/  -> Control UI loads; pair with the token you read on the laptop:
      wsl -d $($site['DISTRO']) -u $($site['WSL_USER']) -- cat ~/.openclaw-ops/gateway-token.txt
   If pairing is rejected with a proxy/origin error: on the laptop  .\windows\21-wsl-openclaw.ps1 -SkipInstall -ProxySource <peer ip from journal>
3. Confirm the URL is NOT reachable from a device outside the tailnet.
4. Slack shows 'Setup complete' and, after the reboot, 'System available'.
5. Then record the confirmations:  .\windows\90-verify.ps1 -Phase 4 -ConfirmRemoteSsh -ConfirmUiPaired
================================================================================================================
"@ -ForegroundColor Green
if ($Reboot -and $To -ge 4) {
    Write-Host 'REBOOTING in 10 seconds (TeamViewer will reconnect; SSH over Tailscale should be back in ~3 min). Ctrl+C to abort.' -ForegroundColor Yellow
    Start-Sleep 10; Restart-Computer -Force
}
