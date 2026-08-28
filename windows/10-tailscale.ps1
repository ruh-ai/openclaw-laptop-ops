<# Phase 1a - Tailscale on WINDOWS (never inside WSL). Idempotent.
   - installs via winget if missing
   - `tailscale up --unattended --hostname --advertise-tags [--auth-key]`  (auth key typed live, never stored)
   - verifies: service running, BackendState=Running, MagicDNS suffix known -> prints TS_TAILNET for site.env
   Pre-req in the Tailscale admin console (human, before the call): MagicDNS + HTTPS certificates enabled;
   tag `TS_TAGS` defined in the ACL with an owner; an auth key (reusable=no, pre-approved=yes, tags=TS_TAGS). #>
param([switch]$NoAuthKey)
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Assert-Admin
$site = Import-SiteConfig
Initialize-OpsRoot | Out-Null
$changed = @(); $verified = @(); $open = @()

$exe = Get-TailscaleExe
if (-not $exe) {
    Write-OpsLog -Component tailscale -Message 'Installing Tailscale via winget'
    winget install --id Tailscale.Tailscale --exact --silent --accept-package-agreements --accept-source-agreements | Out-Null
    Start-Sleep 5; $exe = Get-TailscaleExe
    if (-not $exe) { throw 'Tailscale install did not produce tailscale.exe. Install manually from https://tailscale.com/download/windows and re-run.' }
    $changed += 'Tailscale installed'
}
$svc = Get-Service Tailscale -ErrorAction SilentlyContinue
if (-not $svc) { throw 'Tailscale service not found after install.' }
if ($svc.StartType -ne 'Automatic') { Set-Service Tailscale -StartupType Automatic; $changed += 'Tailscale service set to Automatic' }
if ($svc.Status -ne 'Running') { Start-Service Tailscale; Start-Sleep 3; $changed += 'Tailscale service started' }
# service recovery: restart on failure
& sc.exe failure Tailscale reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

$status = (& $exe status --json 2>$null) | Out-String
$state = if ($status -match '"BackendState":\s*"([^"]+)"') { $Matches[1] } else { 'Unknown' }
Write-OpsLog -Component tailscale -Message "BackendState=$state"

if ($state -ne 'Running') {
    $upArgs = @('up', '--unattended', "--hostname=$($site['TS_HOSTNAME'])", '--accept-dns=true', '--reset')
    if ($site['TS_TAGS']) { $upArgs += "--advertise-tags=$($site['TS_TAGS'])" }
    if (-not $NoAuthKey) {
        Write-Host '[HUMAN AT CONSOLE] Paste the Tailscale auth key (tskey-auth-...). Input hidden. Press Enter with no input to log in interactively via browser instead.' -ForegroundColor Yellow
        $k = Read-Host -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($k); try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($plain) { $upArgs += "--auth-key=$plain" }
    }
    Write-OpsLog -Component tailscale -Message "tailscale up (unattended, hostname=$($site['TS_HOSTNAME']), tags=$($site['TS_TAGS']))"
    & $exe @upArgs
    $plain = $null; $upArgs = $null
    if ($LASTEXITCODE -ne 0) { throw "tailscale up failed (exit $LASTEXITCODE). If it printed a login URL, the human must open it; then re-run this script." }
    $changed += 'tailscale up --unattended'
} else {
    # already up: make sure unattended is on (idempotent, no re-auth)
    & $exe set --unattended=true 2>$null | Out-Null
}

Start-Sleep 2
$status = (& $exe status --json 2>$null) | Out-String
if ($status -notmatch '"BackendState":\s*"Running"') { throw "Tailscale is not Running after up. status: $($status.Substring(0,[Math]::Min(400,$status.Length)))" }
$verified += 'BackendState=Running'
$ip4 = (& $exe ip -4 2>$null | Select-Object -First 1); $verified += "tailnet IPv4 $ip4"
$suffix = if ($status -match '"MagicDNSSuffix":\s*"([^"]+)"') { $Matches[1] } else { '' }
$dns = if ($status -match '"DNSName":\s*"([^"]+)"') { $Matches[1].TrimEnd('.') } else { '' }
if ($suffix) {
    $verified += "MagicDNS suffix $suffix (device DNS name $dns)"
    $envPath = Join-Path (Get-RepoRoot) 'config\site.env'
    $c = Get-Content $envPath
    if ($c -match '^TS_TAILNET=\s*(#.*)?$') { $c = $c -replace '^TS_TAILNET=.*$', "TS_TAILNET=$suffix"; $c | Set-Content $envPath -Encoding UTF8; $changed += "site.env TS_TAILNET=$suffix" }
    elseif (-not ($c -match "^TS_TAILNET=$([regex]::Escape($suffix))")) { $open += "site.env TS_TAILNET differs from live suffix '$suffix' - fix by hand" }
} else { $open += 'MagicDNS suffix not reported - enable MagicDNS in the admin console (required for Serve HTTPS)' }
if ($dns -and $dns -notlike "$($site['TS_HOSTNAME']).*") { $open += "Device DNS name is '$dns', expected '$($site['TS_HOSTNAME']).<tailnet>'. Rename in admin console or set TS_HOSTNAME=$($dns.Split('.')[0])" }

Send-OpsSlack -Title 'Tailscale up on Windows' -Text "$dns ($ip4), unattended mode" -Severity good | Out-Null
Write-PhaseResult -Phase 1 -Pass ($open.Count -eq 0) -Changed $changed -Verified $verified -Open ($open + @('Phase 1 gate also needs 11-openssh.ps1 + SSH test from a second device'))
