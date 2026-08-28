<# Phase 1b — Windows OpenSSH Server, reachable ONLY over Tailscale. Idempotent.
   - installs OpenSSH.Server capability, sshd Automatic + service recovery
   - default shell PowerShell
   - local group SSH_GROUP; WIN_USER added; operator keys from config\operators\*.pub
       * admins use %ProgramData%\ssh\administrators_authorized_keys (Windows rule), ACL SYSTEM:F Administrators:F
       * non-admin operators use C:\Users\<user>\.ssh\authorized_keys
   - sshd_config: PubkeyAuthentication yes, AllowGroups <group>, PasswordAuthentication (kept ON until -DisablePassword)
   - firewall: disables the stock 'OpenSSH-Server-In-TCP' (any address) and adds 'OpenClawOps-SSH-Tailnet' scoped to SSH_TAILNET_CIDR
   Run once, test key login from a second tailnet device, then run again with -DisablePassword. #>
param([switch]$DisablePassword)
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Assert-Admin
$site = Import-SiteConfig
$changed = @(); $verified = @(); $open = @()

$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($cap.State -ne 'Installed') { Write-OpsLog -Component ssh -Message 'Installing OpenSSH.Server'; Add-WindowsCapability -Online -Name $cap.Name | Out-Null; $changed += 'OpenSSH.Server installed' }
Set-Service sshd -StartupType Automatic
& sc.exe failure sshd reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd; $changed += 'sshd started' }

# Default shell = PowerShell
$shell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null }
if ((Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell -ne $shell) { New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null; $changed += 'DefaultShell=powershell' }

# Operator group
$grp = $site['SSH_GROUP']
if (-not (Get-LocalGroup -Name $grp -ErrorAction SilentlyContinue)) { New-LocalGroup -Name $grp -Description 'Allowed to SSH into this laptop over Tailscale' | Out-Null; $changed += "group $grp created" }
if ($site['WIN_USER'] -and -not (Get-LocalGroupMember -Group $grp -Member $site['WIN_USER'] -ErrorAction SilentlyContinue)) { Add-LocalGroupMember -Group $grp -Member $site['WIN_USER']; $changed += "$($site['WIN_USER']) added to $grp" }

# Keys: every config\operators\*.pub -> authorized for WIN_USER (the account both operators use to reach WSL).
# Separate Windows accounts per operator are supported: name the file <windowsuser>.pub and create that local user (+group) by hand; the script routes it.
$pubs = Get-ChildItem (Join-Path (Get-RepoRoot) 'config\operators\*.pub') -ErrorAction SilentlyContinue
if (-not $pubs) { $open += 'No operator keys in config\operators\*.pub — SSH will be password-only until keys are added' }
$adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
$adminSet = New-Object System.Collections.Generic.List[string]
foreach ($f in $pubs) {
    $key = (Get-Content $f -Raw).Trim()
    if ($key -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp\d+|sk-ssh-ed25519@openssh\.com) ') { $open += "$($f.Name) does not look like an OpenSSH public key — skipped"; continue }
    $target = $f.BaseName
    $user = if (Get-LocalUser -Name $target -ErrorAction SilentlyContinue) { $target } else { $site['WIN_USER'] }
    $isAdmin = [bool](Get-LocalGroupMember -Group Administrators -Member $user -ErrorAction SilentlyContinue)
    if ($isAdmin) { $adminSet.Add("$key $($f.BaseName)") }
    else {
        $profileDir = (Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like "*\$user" }).LocalPath
        if (-not $profileDir) { $open += "no profile dir for $user — log in once, then re-run"; continue }
        $ak = Join-Path $profileDir '.ssh\authorized_keys'; New-Item -ItemType Directory -Path (Split-Path $ak) -Force | Out-Null
        if (-not (Test-Path $ak) -or -not ((Get-Content $ak -Raw) -match [regex]::Escape($key))) { Add-Content $ak "$key $($f.BaseName)"; $changed += "key $($f.Name) -> $ak" }
    }
    if ($user -ne $site['WIN_USER'] -and -not (Get-LocalGroupMember -Group $grp -Member $user -ErrorAction SilentlyContinue)) { Add-LocalGroupMember -Group $grp -Member $user; $changed += "$user added to $grp" }
}
if ($adminSet.Count) {
    $existing = if (Test-Path $adminKeys) { Get-Content $adminKeys } else { @() }
    $merged = @($existing) + @($adminSet) | Where-Object { $_.Trim() } | Sort-Object -Unique
    if (($merged -join "`n") -ne ($existing -join "`n")) { Set-Content -Path $adminKeys -Value $merged -Encoding ascii; $changed += "administrators_authorized_keys updated ($($adminSet.Count) keys)" }
    & icacls.exe $adminKeys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
}

# sshd_config drop-in via managed block
$cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
$block = @"
# BEGIN OpenClawOps (managed by windows\11-openssh.ps1 — do not edit by hand)
Port $($site['SSH_PORT'])
PubkeyAuthentication yes
PasswordAuthentication $(if ($DisablePassword) { 'no' } else { 'yes' })
KbdInteractiveAuthentication no
AllowGroups $($grp.ToLower())
ClientAliveInterval 60
ClientAliveCountMax 3
LoginGraceTime 30
MaxAuthTries 4
# END OpenClawOps
"@
$raw = if (Test-Path $cfg) { Get-Content $cfg -Raw } else { '' }
$new = if ($raw -match '(?s)# BEGIN OpenClawOps.*?# END OpenClawOps\r?\n?') { $raw -replace '(?s)# BEGIN OpenClawOps.*?# END OpenClawOps\r?\n?', ($block -replace '\$', '$$$$') } else { $block + "`r`n" + $raw }
if ($new -ne $raw) {
    # comment out the stock Match Group administrators block so our AllowGroups/AuthorizedKeysFile logic is unambiguous
    Set-Content -Path $cfg -Value $new -Encoding ascii
    Restart-Service sshd; $changed += 'sshd_config managed block written; sshd restarted'
}

# Firewall: tailnet only
$stock = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if ($stock -and $stock.Enabled -eq 'True') { Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'; $changed += 'stock any-address SSH rule disabled' }
$rule = Get-NetFirewallRule -Name 'OpenClawOps-SSH-Tailnet' -ErrorAction SilentlyContinue
if (-not $rule) {
    New-NetFirewallRule -Name 'OpenClawOps-SSH-Tailnet' -DisplayName 'OpenClawOps SSH (Tailscale only)' -Direction Inbound -Protocol TCP -LocalPort $site['SSH_PORT'] -RemoteAddress $site['SSH_TAILNET_CIDR'] -Action Allow -Profile Any | Out-Null
    $changed += "firewall rule OpenClawOps-SSH-Tailnet ($($site['SSH_TAILNET_CIDR']))"
}

# Verify
if ((Get-Service sshd).Status -eq 'Running') { $verified += 'sshd running' } else { $open += 'sshd not running' }
if (Test-TcpPort -Port ([int]$site['SSH_PORT'])) { $verified += "sshd listening on $($site['SSH_PORT'])" } else { $open += 'sshd port not open locally' }
$tsExe = Get-TailscaleExe; $ip4 = if ($tsExe) { & $tsExe ip -4 2>$null | Select-Object -First 1 } else { '<tailnet-ip>' }
$open += "[HUMAN AT CONSOLE / SECOND DEVICE] From another tailnet device: ssh $($site['WIN_USER'])@$ip4  (and: ssh $($site['WIN_USER'])@$($site['TS_HOSTNAME'])). Key login must work before running with -DisablePassword."
if (-not $DisablePassword) { $open += 'PasswordAuthentication is still YES. After key login is confirmed: .\windows\11-openssh.ps1 -DisablePassword' } else { $verified += 'PasswordAuthentication no' }
Write-PhaseResult -Phase 1 -Pass $false -Changed $changed -Verified $verified -Open $open
Write-Host 'Phase 1 gate is closed by: .\windows\90-verify.ps1 -Phase 1 (after the remote SSH test).' -ForegroundColor Cyan
