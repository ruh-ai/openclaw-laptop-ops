#Requires -Version 5.1
<#
.SYNOPSIS
  Shared library for openclaw-laptop-ops Windows scripts.
  PROTECTED after Phase 1 - see AGENTS.md rule 2.

  Contract:
    Import-SiteConfig            -> hashtable of config/site.env (+ derived keys), also $global:Site
    Initialize-OpsRoot           -> creates %OPS_ROOT_WIN% tree with restricted ACL
    Write-OpsLog                 -> logs\ops.log (text) + logs\events.jsonl (JSON lines) + console
    Set-OpsSecret / Get-OpsSecret-> DPAPI (current user) secrets in secrets\<name>.xml
    Send-OpsSlack                -> Slack webhook, queued to secrets\..\slack-queue.jsonl on failure
    Enter-OpsLock / Exit-OpsLock -> single-instance lock with stale-PID detection
    Get-OpsState / Set-OpsState  -> state.json (phase, health counters, incidents)
    Invoke-WslBash               -> run a bash command/script inside DISTRO as WSL_USER (or root)
    Assert-Admin, Test-TcpPort, ConvertTo-WslPath, Get-TailscaleExe, Write-PhaseResult
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not (Get-Variable -Name Site -Scope Global -ErrorAction SilentlyContinue)) { $global:Site = $null }

function Get-RepoRoot {
    # windows/lib/Common.psm1 -> repo root
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Import-SiteConfig {
    param([switch]$AllowExample)
    $root = Get-RepoRoot
    $path = Join-Path $root 'config\site.env'
    if (-not (Test-Path $path)) {
        if ($AllowExample) { $path = Join-Path $root 'config\site.env.example' }
        else { throw "config\site.env not found. Run Phase 0 (windows\00-discovery.ps1) first, or copy config\site.env.example." }
    }
    $cfg = [ordered]@{}
    foreach ($line in Get-Content $path) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $kv = $l -split '=', 2
        if ($kv.Count -ne 2) { continue }
        $k = $kv[0].Trim()
        $v = $kv[1]
        # strip inline comment (first ' #' or leading '#')
        $hash = $v.IndexOf(' #'); if ($hash -ge 0) { $v = $v.Substring(0, $hash) }
        $v = $v.Trim().Trim('"').Trim("'")
        $cfg[$k] = $v
    }
    # Derived values
    if (-not $cfg['REPO_DIR_WIN']) { $cfg['REPO_DIR_WIN'] = $root }
    if (-not $cfg['OPS_ROOT_WIN']) { $cfg['OPS_ROOT_WIN'] = 'C:\ProgramData\openclaw-ops' }
    $cfg['REPO_DIR_WSL'] = ConvertTo-WslPath $cfg['REPO_DIR_WIN']
    $cfg['OPS_ROOT_WSL'] = ConvertTo-WslPath $cfg['OPS_ROOT_WIN']
    if ($cfg['TS_HOSTNAME'] -and $cfg['TS_TAILNET']) { $cfg['TS_URL'] = "https://$($cfg['TS_HOSTNAME']).$($cfg['TS_TAILNET'])" } else { $cfg['TS_URL'] = '' }
    if (-not $cfg['GATEWAY_PORT']) { $cfg['GATEWAY_PORT'] = '18789' }
    $cfg['LOCAL_GATEWAY_URL'] = "http://127.0.0.1:$($cfg['GATEWAY_PORT'])"
    $global:Site = $cfg
    return $cfg
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WindowsPath)
    $p = $WindowsPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') { return "/mnt/$($Matches[1].ToLower())$($Matches[2])" }
    return $p
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-Admin { if (-not (Test-IsAdmin)) { throw 'This script must run in an elevated (Administrator) PowerShell.' } }

function Initialize-OpsRoot {
    param([hashtable]$Site = $global:Site)
    $ops = $Site['OPS_ROOT_WIN']
    foreach ($d in @('', 'logs', 'secrets', 'backups', 'backups\daily', 'backups\weekly', 'snapshots', 'reports', 'queue')) {
        $p = if ($d) { Join-Path $ops $d } else { $ops }
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    # ACL: SYSTEM, Administrators, and the owning user only. Secrets are additionally DPAPI-bound to WIN_USER.
    try {
        $acl = Get-Acl $ops
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        foreach ($who in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($who, 'FullControl', $inherit, 'None', 'Allow')))
        }
        if ($Site['WIN_USER']) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($Site['WIN_USER'], 'FullControl', $inherit, 'None', 'Allow')))
        }
        Set-Acl $ops $acl
    } catch { Write-Warning "Could not tighten ACL on $ops : $_" }
    return $ops
}

function Write-OpsLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'ALERT')][string]$Level = 'INFO',
        [string]$Component = 'ops',
        [hashtable]$Data
    )
    $ops = if ($global:Site) { $global:Site['OPS_ROOT_WIN'] } else { 'C:\ProgramData\openclaw-ops' }
    $logDir = Join-Path $ops 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    $line = "$ts [$Level] [$Component] $Message"
    Add-Content -Path (Join-Path $logDir 'ops.log') -Value $line -Encoding UTF8
    $evt = [ordered]@{ ts = $ts; level = $Level; component = $Component; message = $Message }
    if ($Data) { $evt['data'] = $Data }
    Add-Content -Path (Join-Path $logDir 'events.jsonl') -Value ($evt | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8
    $color = switch ($Level) { 'ERROR' { 'Red' } 'ALERT' { 'Magenta' } 'WARN' { 'Yellow' } 'DEBUG' { 'DarkGray' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}

# ---------------- Secrets (DPAPI, current-user scope) ----------------
# IMPORTANT: DPAPI CurrentUser means Set- and Get- must run as the SAME Windows account (WIN_USER),
# which is also the account the scheduled tasks run as. Running Set-OpsSecret as a different admin
# account produces a blob the supervisor cannot decrypt.
function Get-OpsSecretPath { param([string]$Name) return (Join-Path (Join-Path $global:Site['OPS_ROOT_WIN'] 'secrets') "$Name.xml") }

function Set-OpsSecret {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][securestring]$Value)
    $path = Get-OpsSecretPath $Name
    $Value | Export-Clixml -Path $path -Force
    $acl = Get-Acl $path; $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    foreach ($who in @('NT AUTHORITY\SYSTEM', "$env:USERDOMAIN\$env:USERNAME")) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($who, 'FullControl', 'Allow')))
    }
    Set-Acl $path $acl
    Write-OpsLog -Component secrets -Message "Secret '$Name' stored (DPAPI, user $env:USERNAME)"
}

function Get-OpsSecret {
    param([Parameter(Mandatory)][string]$Name)
    $path = Get-OpsSecretPath $Name
    if (-not (Test-Path $path)) { return $null }
    $ss = Import-Clixml -Path $path
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ---------------- Slack ----------------
function Send-OpsSlack {
    <# State-change messages only. Never include secrets. Queues on failure; Flush-OpsSlackQueue retries. #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Text = '',
        [ValidateSet('good', 'warning', 'danger', 'info')][string]$Severity = 'info',
        [hashtable]$Fields
    )
    $site = $global:Site['SITE_NAME']
    $emoji = switch ($Severity) { 'good' { ':white_check_mark:' } 'warning' { ':warning:' } 'danger' { ':rotating_light:' } default { ':information_source:' } }
    $body = "$emoji *[$site]* $Title"
    if ($Text) { $body += "`n$Text" }
    if ($Fields) { $body += "`n" + (($Fields.GetEnumerator() | ForEach-Object { "* *$($_.Key)*: $($_.Value)" }) -join "`n") }
    $payload = @{ text = $body } | ConvertTo-Json -Compress -Depth 4
    $queue = Join-Path $global:Site['OPS_ROOT_WIN'] 'queue\slack-queue.jsonl'
    $hook = Get-OpsSecret -Name slack
    if (-not $hook) {
        Write-OpsLog -Level WARN -Component slack -Message "No Slack webhook stored; message queued: $Title"
        Add-Content -Path $queue -Value $payload -Encoding UTF8; return $false
    }
    try {
        Invoke-RestMethod -Uri $hook -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 10 | Out-Null
        Write-OpsLog -Component slack -Message "Sent: $Title"
        return $true
    } catch {
        Write-OpsLog -Level WARN -Component slack -Message "Send failed ($($_.Exception.Message)); queued: $Title"
        Add-Content -Path $queue -Value $payload -Encoding UTF8
        return $false
    }
}

function Flush-OpsSlackQueue {
    $queue = Join-Path $global:Site['OPS_ROOT_WIN'] 'queue\slack-queue.jsonl'
    if (-not (Test-Path $queue)) { return }
    $hook = Get-OpsSecret -Name slack
    if (-not $hook) { return }
    $lines = Get-Content $queue | Where-Object { $_.Trim() }
    if (-not $lines) { Remove-Item $queue -Force; return }
    $remaining = @()
    foreach ($l in $lines) {
        try { Invoke-RestMethod -Uri $hook -Method Post -ContentType 'application/json' -Body $l -TimeoutSec 10 | Out-Null }
        catch { $remaining += $l }
    }
    if ($remaining) { Set-Content -Path $queue -Value $remaining -Encoding UTF8 } else { Remove-Item $queue -Force }
    Write-OpsLog -Component slack -Message "Queue flushed; $($lines.Count - $remaining.Count) sent, $($remaining.Count) still queued"
}

# ---------------- Lock ----------------
function Enter-OpsLock {
    param([string]$Name = 'supervisor', [int]$StaleMinutes = 30)
    $path = Join-Path $global:Site['OPS_ROOT_WIN'] "queue\$Name.lock"
    if (Test-Path $path) {
        try {
            $info = Get-Content $path -Raw | ConvertFrom-Json
            $alive = Get-Process -Id $info.pid -ErrorAction SilentlyContinue
            $age = (Get-Date) - [datetime]$info.ts
            if ($alive -and $age.TotalMinutes -lt $StaleMinutes) { return $false }
            Write-OpsLog -Level WARN -Component lock -Message "Stale lock '$Name' (pid $($info.pid), age $([int]$age.TotalMinutes)m) - taking over"
        } catch { Write-OpsLog -Level WARN -Component lock -Message "Unreadable lock '$Name' - taking over" }
    }
    @{ pid = $PID; ts = (Get-Date).ToString('o'); host = $env:COMPUTERNAME } | ConvertTo-Json -Compress | Set-Content -Path $path -Encoding UTF8
    return $true
}
function Exit-OpsLock { param([string]$Name = 'supervisor') $p = Join-Path $global:Site['OPS_ROOT_WIN'] "queue\$Name.lock"; if (Test-Path $p) { Remove-Item $p -Force } }

# ---------------- State ----------------
function Get-OpsState {
    $path = Join-Path $global:Site['OPS_ROOT_WIN'] 'state.json'
    if (-not (Test-Path $path)) {
        return [ordered]@{
            phase = 0; recoveryMode = $global:Site['RECOVERY_MODE']; lastHealthy = $null; lastCheck = $null
            consecutiveFailures = 0; consecutiveHealthy = 0; status = 'unknown'; recoveryStep = 'none'
            aiRepairs = @(); incidents = @(); lastBootId = $null; lastHeartbeat = $null; lastKnownGoodSnapshot = $null
        }
    }
    $obj = Get-Content $path -Raw | ConvertFrom-Json
    $h = [ordered]@{}; $obj.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
    return $h
}
function Set-OpsState { param([Parameter(Mandatory)]$State)
    $path = Join-Path $global:Site['OPS_ROOT_WIN'] 'state.json'
    $tmp = "$path.tmp"; ($State | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding UTF8; Move-Item -Force $tmp $path
}

# ---------------- WSL ----------------
function Invoke-WslBash {
    <# Run a bash command inside DISTRO. Returns @{ExitCode; Output}. Login shell so PATH (~/.local/bin, npm) is loaded.
       The command is written to a temp file under OPS_ROOT\queue and executed by path - no Windows/bash quoting games. #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [switch]$AsRoot,
        [int]$TimeoutSec = 600
    )
    $distro = $global:Site['DISTRO']
    $user = if ($AsRoot) { 'root' } else { $global:Site['WSL_USER'] }
    $qdir = Join-Path $global:Site['OPS_ROOT_WIN'] 'queue'
    if (-not (Test-Path $qdir)) { New-Item -ItemType Directory -Path $qdir -Force | Out-Null }
    $tmpWin = Join-Path $qdir ("cmd-" + [guid]::NewGuid().ToString('n') + ".sh")
    # LF line endings, UTF-8 without BOM
    [IO.File]::WriteAllText($tmpWin, ("set -o pipefail`n" + $Command + "`n"), (New-Object Text.UTF8Encoding($false)))
    $tmpWsl = ConvertTo-WslPath $tmpWin
    $outFile = "$tmpWin.out"
    try {
        $p = Start-Process -FilePath 'wsl.exe' -ArgumentList @('-d', $distro, '-u', $user, '--', 'bash', '-l', $tmpWsl) `
            -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch {}; return @{ ExitCode = 124; Output = "TIMEOUT after ${TimeoutSec}s" } }
        $out = ''
        if (Test-Path $outFile) { $out += Get-Content $outFile -Raw -ErrorAction SilentlyContinue }
        if (Test-Path "$outFile.err") { $err = Get-Content "$outFile.err" -Raw -ErrorAction SilentlyContinue; if ($err) { $out += "`n" + $err } }
        return @{ ExitCode = $p.ExitCode; Output = (("$out") -replace "`0", '').TrimEnd() }
    } finally {
        Remove-Item $tmpWin, $outFile, "$outFile.err" -Force -ErrorAction SilentlyContinue
    }
}
function Invoke-WslScript {
    <# Run a repo script (path relative to repo root, e.g. wsl/healthcheck.sh) inside WSL. #>
    param([Parameter(Mandatory)][string]$Script, [string[]]$Arguments = @(), [switch]$AsRoot, [int]$TimeoutSec = 600)
    $repoWsl = $global:Site['REPO_DIR_WSL']
    $quoted = ($Arguments | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
    $envPrefix = "OPS_SITE_ENV='$repoWsl/config/site.env' OPS_REPO='$repoWsl' OPS_ROOT_WSL='$($global:Site['OPS_ROOT_WSL'])'"
    return Invoke-WslBash -Command "$envPrefix bash '$repoWsl/$Script' $quoted" -AsRoot:$AsRoot -TimeoutSec $TimeoutSec
}
function Test-WslRunning { param([string]$Distro = $global:Site['DISTRO'])
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    try { $out = ((@(& wsl.exe --list --running 2>$null) | ForEach-Object { "$_" }) -join "`n") -replace "`0", '' } catch { return $false }
    return [bool]($out -match [regex]::Escape($Distro))
}

# ---------------- Misc ----------------
function Get-TailscaleExe { $p = 'C:\Program Files\Tailscale\tailscale.exe'; if (Test-Path $p) { return $p }; $c = Get-Command tailscale.exe -ErrorAction SilentlyContinue; if ($c) { return $c.Source }; return $null }

function Test-TcpPort { param([string]$HostName = '127.0.0.1', [Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 3000)
    $c = New-Object Net.Sockets.TcpClient
    try { $ar = $c.BeginConnect($HostName, $Port, $null, $null); if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }; $c.EndConnect($ar); return $true } catch { return $false } finally { $c.Dispose() }
}

function Test-HttpOk { param([Parameter(Mandatory)][string]$Url, [int]$TimeoutSec = 8)
    try { $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 2; return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) }
    catch { if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -in 401, 403) { return $true }; return $false }
}

function Write-PhaseResult { param([int]$Phase, [bool]$Pass, [string[]]$Changed = @(), [string[]]$Verified = @(), [string[]]$Open = @())
    $status = if ($Pass) { 'PASS' } else { 'FAIL' }
    Write-Host "`nPHASE $Phase $status" -ForegroundColor $(if ($Pass) { 'Green' } else { 'Red' })
    if ($Changed) { Write-Host 'changed:'; $Changed | ForEach-Object { Write-Host "  - $_" } }
    if ($Verified) { Write-Host 'verified:'; $Verified | ForEach-Object { Write-Host "  - $_" } }
    if ($Open) { Write-Host 'open:'; $Open | ForEach-Object { Write-Host "  - $_" } }
    if ($Pass) { $s = Get-OpsState; if ([int]$s.phase -lt $Phase) { $s.phase = $Phase; Set-OpsState $s } }
}

Export-ModuleMember -Function *
