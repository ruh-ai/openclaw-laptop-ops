<# Phase 2a — WSL 2 runtime standardisation. Idempotent.
   - WSL up to date (wsl --update), DISTRO exists and is version 2
   - %USERPROFILE%\.wslconfig managed block: localhostForwarding, vmIdleTimeout, memory  (NAT mode kept; mirrored not required)
   - /etc/wsl.conf: [boot] systemd=true ; [user] default=WSL_USER
   - Linux user WSL_USER exists (sudo, NOPASSWD for service mgmt only), linger enabled
   - restarts the distro (wsl --terminate DISTRO, NOT --shutdown) and verifies PID 1 = systemd
   Requires Phase 1 gate (SSH over Tailscale works) because the distro restart drops any in-WSL sessions. #>
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Assert-Admin
$site = Import-SiteConfig
$changed = @(); $verified = @(); $open = @()
$distro = $site['DISTRO']; $wuser = $site['WSL_USER']

$list = (& wsl.exe -l -v 2>&1) -replace "`0", '' | Out-String
if ($list -notmatch [regex]::Escape($distro)) { throw "Distro '$distro' not found in 'wsl -l -v'. Fix DISTRO in site.env (discovery report lists the names)." }
if ($list -match "(?m)^\s*\*?\s*$([regex]::Escape($distro))\s+\S+\s+1\s*$") { throw "$distro is WSL 1. Convert: wsl --set-version $distro 2 (human decision; takes minutes)." }
try { & wsl.exe --update 2>&1 | Out-Null } catch {}
$verified += "distro $distro present (WSL2)"

# .wslconfig (user-scope of WIN_USER — run this script as WIN_USER)
$wslcfg = Join-Path $env:USERPROFILE '.wslconfig'
$idle = $site['WSL_VM_IDLE_TIMEOUT_MS']; $mem = $site['WSL_MEMORY']
$block = "# BEGIN OpenClawOps (managed by windows\20-wsl-prepare.ps1)`n[wsl2]`nlocalhostForwarding=true`nvmIdleTimeout=$idle`n" + $(if ($mem) { "memory=$mem`n" } else { '' }) + "# END OpenClawOps`n"
$raw = if (Test-Path $wslcfg) { Get-Content $wslcfg -Raw } else { '' }
if ($raw -match '(?s)# BEGIN OpenClawOps.*?# END OpenClawOps\r?\n?') { $new = $raw -replace '(?s)# BEGIN OpenClawOps.*?# END OpenClawOps\r?\n?', ($block -replace '\$', '$$$$') }
else { if ($raw -match '(?m)^\[wsl2\]') { $open += ".wslconfig already has a [wsl2] section outside our block — merge by hand: $wslcfg" }; $new = $block + $raw }
if ($new -ne $raw) { Set-Content $wslcfg $new -Encoding ascii; $changed += ".wslconfig managed block (vmIdleTimeout=$idle)" }

# Inside the distro, as root
$script = @"
set -e
id -u '$wuser' >/dev/null 2>&1 || { useradd -m -s /bin/bash -G sudo '$wuser'; echo 'created user $wuser'; }
install -d -m 755 /etc/sudoers.d
cat > /etc/sudoers.d/90-openclaw-ops <<'SUDO'
# openclaw-ops: WSL_USER may manage its own services and read journals without a password; nothing else.
$wuser ALL=(root) NOPASSWD: /usr/bin/systemctl, /usr/bin/journalctl, /usr/bin/loginctl, /usr/bin/apt-get, /usr/bin/apt
SUDO
chmod 440 /etc/sudoers.d/90-openclaw-ops
python3 - <<'PY' 2>/dev/null || true
import re,io
p='/etc/wsl.conf'
try: s=open(p).read()
except FileNotFoundError: s=''
def setkv(s,sec,k,v):
    if re.search(r'(?m)^\[%s\]'%sec,s):
        body=re.split(r'(?m)^\[%s\]\s*$'%sec,s,1)[1]; end=re.search(r'(?m)^\[',body); seg=body[:end.start()] if end else body
        if re.search(r'(?m)^\s*%s\s*='%k,seg): seg2=re.sub(r'(?m)^\s*%s\s*=.*$'%k,'%s=%s'%(k,v),seg)
        else: seg2=seg.rstrip('\n')+'\n%s=%s\n'%(k,v)
        return s.replace(seg,seg2,1)
    return s.rstrip('\n')+('\n\n' if s.strip() else '')+'[%s]\n%s=%s\n'%(sec,k,v)
s=setkv(s,'boot','systemd','true'); s=setkv(s,'user','default','$wuser')
open(p,'w').write(s); print('wsl.conf updated')
PY
grep -q 'systemd=true' /etc/wsl.conf || { printf '\n[boot]\nsystemd=true\n[user]\ndefault=$wuser\n' >> /etc/wsl.conf; echo 'wsl.conf appended'; }
command -v dbus-launch >/dev/null || { apt-get update -qq && apt-get install -y -qq dbus-x11 >/dev/null; echo 'dbus-x11 installed'; }
loginctl enable-linger '$wuser' 2>/dev/null || true
echo "pid1=\$(ps -p 1 -o comm=)"
"@
$r = Invoke-WslBash -Command $script -AsRoot -TimeoutSec 600
Write-Host $r.Output
if ($r.ExitCode -ne 0) { throw "in-distro preparation failed (exit $($r.ExitCode))" }
if ($r.Output -match 'created user|wsl.conf (updated|appended)|dbus-x11 installed') { $changed += 'distro: user/sudoers/wsl.conf/dbus prepared' }

if ($r.Output -notmatch 'pid1=systemd') {
    Write-OpsLog -Component wsl -Message "Restarting distro $distro to apply systemd (wsl --terminate)"
    & wsl.exe --terminate $distro | Out-Null; Start-Sleep 10
    $chk = Invoke-WslBash -Command 'ps -p 1 -o comm=' -AsRoot -TimeoutSec 120
    if ($chk.Output -match 'systemd') { $verified += 'PID 1 = systemd'; $changed += 'distro restarted' }
    else { $open += "systemd still not PID 1 after restart (got '$($chk.Output.Trim())'). WSL may need 'wsl --shutdown' (stops ALL distros) — human decision, then re-run." }
} else { $verified += 'PID 1 = systemd' }

$lin = Invoke-WslBash -Command "loginctl show-user '$wuser' -p Linger --value 2>/dev/null || echo unknown" -AsRoot
if ($lin.Output -match 'yes') { $verified += "linger enabled for $wuser" } else { $open += "linger not confirmed for $wuser (got '$($lin.Output.Trim())')" }
Write-PhaseResult -Phase 2 -Pass $false -Changed $changed -Verified $verified -Open ($open + @('continue with 21-wsl-openclaw.ps1'))
