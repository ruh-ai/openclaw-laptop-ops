<# Phase 4b - Windows resilience settings. Idempotent. Only touches AC (plugged-in) behaviour. #>
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Assert-Admin
$site = Import-SiteConfig
$changed = @(); $verified = @()
if ($site['DISABLE_SLEEP_ON_AC'] -eq 'true') {
    powercfg /change standby-timeout-ac 0 | Out-Null; powercfg /change hibernate-timeout-ac 0 | Out-Null; powercfg /change monitor-timeout-ac 15 | Out-Null
    powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 0 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
    $changed += 'no sleep/hibernate on AC'
}
if ($site['LID_CLOSE_DOES_NOTHING_ON_AC'] -eq 'true') {
    # SUB_BUTTONS / LIDACTION : 0 = do nothing
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null; powercfg /setactive SCHEME_CURRENT | Out-Null
    $changed += 'lid close = do nothing on AC'
}
# NIC power saving off (all physical adapters)
Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
    try { Disable-NetAdapterPowerManagement -Name $_.Name -NoRestart -ErrorAction Stop; $changed += "NIC power mgmt off: $($_.Name)" } catch {}
}
# Fast startup off (it hibernates the kernel and can leave WSL/Tailscale in odd states after "shutdown")
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -PropertyType DWord -Force | Out-Null
$changed += 'fast startup disabled'
# Windows Update active hours 08:00-18:00 so restarts land at night (boot sequence recovers)
$au = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
if (Test-Path $au) { Set-ItemProperty $au -Name ActiveHoursStart -Value 8 -Type DWord; Set-ItemProperty $au -Name ActiveHoursEnd -Value 18 -Type DWord; $changed += 'update active hours 08-18' }
$verified += (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String 'AC Power Setting Index').ToString().Trim()
Write-OpsLog -Component power -Message ($changed -join '; ')
Write-PhaseResult -Phase 4 -Pass $false -Changed $changed -Verified $verified -Open @('Firmware "power on after AC loss" is a BIOS setting - human, if supported', 'Windows Update may still reboot within the maintenance window; the boot sequence must recover (reboot test)')
