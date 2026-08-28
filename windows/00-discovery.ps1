<# Phase 0 — Discovery. Read-only. Writes %OPS_ROOT%\reports\discovery-<ts>.md + .json and proposes site.env values.
   Nothing is changed on the machine except the report files. #>
param([switch]$WriteSiteEnv)
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$site = Import-SiteConfig -AllowExample
Initialize-OpsRoot | Out-Null
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$rep = [ordered]@{}
function Probe($name, [scriptblock]$sb) { try { $rep[$name] = (& $sb) } catch { $rep[$name] = "ERROR: $($_.Exception.Message)" } }
function W { param([string[]]$WslArgs) $o = & wsl.exe @WslArgs 2>&1; return ((@($o) | ForEach-Object { "$_" }) -join "`n") -replace "`0", '' }

Probe 'windows' { [ordered]@{ caption = (Get-CimInstance Win32_OperatingSystem).Caption; version = [Environment]::OSVersion.Version.ToString(); build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion; computer = $env:COMPUTERNAME; user = "$env:USERDOMAIN\$env:USERNAME"; isAdmin = (Test-IsAdmin); lastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o') } }
Probe 'hardware' { $cs = Get-CimInstance Win32_ComputerSystem; $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue; [ordered]@{ model = "$($cs.Manufacturer) $($cs.Model)"; ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1); cpu = (Get-CimInstance Win32_Processor).Name; battery = [bool]$bat; onAC = if ($bat) { $bat.BatteryStatus -eq 2 } else { $true } } }
Probe 'disk' { Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | ForEach-Object { [ordered]@{ drive = $_.Name; freeGB = [math]::Round($_.Free / 1GB, 1); usedPct = [math]::Round(100 * $_.Used / ($_.Used + $_.Free), 0) } } }
Probe 'power' { (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String 'AC Power Setting Index').ToString().Trim() }
Probe 'wsl.version' { W @('--version') }
Probe 'wsl.status' { W @('--status') }
Probe 'wsl.distros' { W @('-l','-v') }
Probe 'wsl.running' { W @('-l','--running') }
Probe 'wsl.registryOwner' { Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue | ForEach-Object { $p = Get-ItemProperty $_.PSPath; [ordered]@{ name = $p.DistributionName; basePath = $p.BasePath; defaultUid = $p.DefaultUid; ownerWinUser = $env:USERNAME } } }
Probe 'wslconfig' { $f = Join-Path $env:USERPROFILE '.wslconfig'; if (Test-Path $f) { Get-Content $f -Raw } else { '(none)' } }
Probe 'tailscale' { $exe = Get-TailscaleExe; if ($exe) { [ordered]@{ exe = $exe; version = (& $exe version 2>&1 | Select-Object -First 1); status = (& $exe status --json 2>&1 | Out-String) } } else { 'not installed' } }
Probe 'sshd' { $s = Get-Service sshd -ErrorAction SilentlyContinue; if ($s) { [ordered]@{ status = $s.Status.ToString(); startType = $s.StartType.ToString() } } else { 'not installed' } }
Probe 'teamviewer' { $s = Get-Service TeamViewer -ErrorAction SilentlyContinue; if ($s) { $s.Status.ToString() } else { 'service not found' } }
Probe 'listeners' { Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, OwningProcess | Sort-Object LocalPort | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort) pid=$($_.OwningProcess)" } }
Probe 'scheduledTasks' { Get-ScheduledTask -TaskName 'OpenClawOps-*', 'WSL*' -ErrorAction SilentlyContinue | ForEach-Object { "$($_.TaskName) [$($_.State)] as $($_.Principal.UserId)" } }
Probe 'node' { (& node --version 2>&1); (& npm --version 2>&1) }
Probe 'agents' { [ordered]@{ codex = [bool](Get-Command codex -ErrorAction SilentlyContinue); claude = [bool](Get-Command claude -ErrorAction SilentlyContinue) } }

# Inside WSL (only if a distro is present and site.env names it)
$distro = $site['DISTRO']
$distroList = "$($rep['wsl.distros'])"
if ($distro -and $distroList -match [regex]::Escape($distro)) {
    $global:Site['WSL_USER'] = 'root'
    Probe 'wsl.inside' {
        $cmd = @'
echo "os=$(. /etc/os-release && echo $PRETTY_NAME)"; echo "kernel=$(uname -r)"; echo "systemd_pid1=$(ps -p 1 -o comm=)"
echo "wslconf=$(cat /etc/wsl.conf 2>/dev/null | tr '\n' ';')"; echo "users=$(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd | tr '\n' ' ')"
echo "linger=$(ls /var/lib/systemd/linger 2>/dev/null | tr '\n' ' ')"; echo "disk_root=$(df -h / | awk 'NR==2{print $5" used, "$4" free"}')"
echo "node=$(command -v node && node --version 2>/dev/null)"; echo "openclaw=$(command -v openclaw || echo none)"
for u in $(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd); do h=$(eval echo ~$u); [ -d "$h/.openclaw" ] && echo "openclaw_home=$h/.openclaw (user $u)"; [ -f "$h/.config/systemd/user/openclaw-gateway.service" ] && echo "unit=$h/.config/systemd/user/openclaw-gateway.service (user $u)"; done
echo "listen=$(ss -ltnp 2>/dev/null | awk 'NR>1{print $4}' | tr '\n' ' ')"; echo "wsl_ip=$(hostname -I 2>/dev/null)"
'@
        (Invoke-WslBash -Command $cmd -AsRoot -TimeoutSec 120).Output
    }
}

# ---- Report ----
$reports = Join-Path $site['OPS_ROOT_WIN'] 'reports'
$json = Join-Path $reports "discovery-$ts.json"; $md = Join-Path $reports "discovery-$ts.md"
$rep | ConvertTo-Json -Depth 6 | Set-Content $json -Encoding UTF8
$lines = @("# Discovery $ts", '', "Machine: $($rep['windows'].computer)  User: $($rep['windows'].user)", '')
foreach ($k in $rep.Keys) { $lines += "## $k"; $lines += '```'; $lines += (($rep[$k] | ConvertTo-Json -Depth 6) -split "`n"); $lines += '```'; $lines += '' }
$lines | Set-Content $md -Encoding UTF8
Write-Host "Report: $md" -ForegroundColor Green

# ---- Proposed site.env values (VERIFY-ON-SITE) ----
$proposed = [ordered]@{ WIN_USER = $env:USERNAME }
$m = [regex]::Matches($distroList, '(?m)^\s*\*?\s*(\S+)\s+(Running|Stopped)\s+(\d)')
if ($m.Count -ge 1) { $proposed['DISTRO'] = $m[0].Groups[1].Value }
$tsj = $rep['tailscale']; if ($tsj -is [System.Collections.IDictionary] -and $tsj.status -match '"MagicDNSSuffix":\s*"([^"]+)"') { $proposed['TS_TAILNET'] = $Matches[1] }
$inside = "$($rep['wsl.inside'])"
if ($inside -match 'openclaw_home=(\S+) \(user (\S+)\)') { $proposed['OPENCLAW_HOME'] = $Matches[1]; $proposed['WSL_USER'] = $Matches[2]; $proposed['WSL_HOME'] = (Split-Path $Matches[1] -Parent) -replace '\\', '/'; $proposed['OPENCLAW_INSTALL_METHOD'] = 'existing' }
Write-Host "`nProposed site.env values (verify each against the report before accepting):" -ForegroundColor Cyan
$proposed.GetEnumerator() | ForEach-Object { Write-Host ("  {0}={1}" -f $_.Key, $_.Value) }
if ($WriteSiteEnv) {
    $envPath = Join-Path (Get-RepoRoot) 'config\site.env'
    if (-not (Test-Path $envPath)) { Copy-Item (Join-Path (Get-RepoRoot) 'config\site.env.example') $envPath }
    $content = Get-Content $envPath
    foreach ($kv in $proposed.GetEnumerator()) {
        $pattern = "^$([regex]::Escape($kv.Key))="
        if ($content -match $pattern) { $content = $content -replace "($pattern)[^#]*", ('${1}' + $kv.Value + ' ') } else { $content += "$($kv.Key)=$($kv.Value)" }
    }
    $content | Set-Content $envPath -Encoding UTF8
    Write-Host "config\site.env updated with proposed values. Review it now." -ForegroundColor Green
}
Write-Host "`nVERIFY-ON-SITE checklist: DISTRO name exact; WIN_USER owns the distro (wsl.registryOwner); systemd_pid1 should be 'systemd' after Phase 2; note wsl_ip (NAT) for trustedProxies verification in Phase 3."
