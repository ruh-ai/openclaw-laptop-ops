<# Phase 4a - Scheduled tasks (all run as WIN_USER, "whether user is logged on or not"). Idempotent.
   OpenClawOps-WSLBoot        at startup (+30s)   wsl.exe -d DISTRO --exec dbus-launch true   (OpenClaw's documented keep-alive form)
   OpenClawOps-Supervisor     every SUPERVISOR_INTERVAL_MIN, also at startup   windows\supervisor\Supervisor.ps1
   OpenClawOps-BackupNightly  daily BACKUP_NIGHTLY_TIME                        windows\backup\Backup-OpenClaw.ps1
   OpenClawOps-WslExportWeekly weekly WSL_EXPORT_DAY WSL_EXPORT_TIME           windows\backup\Export-Wsl.ps1
   [HUMAN AT CONSOLE] Windows asks for WIN_USER's password once (LogonType Password) so tasks run before login.
   WSL distros are per-user: SYSTEM or S4U would not see the distro. PROTECTED after creation (AGENTS.md rule 2). #>
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Assert-Admin
$site = Import-SiteConfig
$changed = @(); $verified = @(); $open = @()
$user = $site['WIN_USER']; if (-not $user) { throw 'WIN_USER empty in site.env' }
if ($env:USERNAME -ne $user) { $open += "Running as $env:USERNAME, tasks will run as $user. DPAPI secrets (Slack) must have been set by $user." }
$repo = $site['REPO_DIR_WIN']; $ps = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
Write-Host "[HUMAN AT CONSOLE] Enter the Windows password for '$user' (stored by Task Scheduler, not by this repo)." -ForegroundColor Yellow
$cred = Get-Credential -UserName $user -Message "Password for $user (scheduled tasks run before login)"
$pw = $cred.GetNetworkCredential().Password

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
function Register($name, $action, $triggers, $limitMin) {
    $s = $settings; if ($limitMin) { $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes $limitMin) }
    $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($existing) { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $triggers -Settings $s -User $user -Password $pw -RunLevel Highest -Description 'openclaw-laptop-ops (PROTECTED - see AGENTS.md)' | Out-Null
    $script:changed += "task $name $(if ($existing) { 'replaced' } else { 'created' })"
}
$boot = New-ScheduledTaskTrigger -AtStartup; $boot.Delay = 'PT30S'
Register 'OpenClawOps-WSLBoot' (New-ScheduledTaskAction -Execute 'C:\Windows\System32\wsl.exe' -Argument "-d $($site['DISTRO']) --exec dbus-launch true") @($boot) 10

$every = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes ([int]$site['SUPERVISOR_INTERVAL_MIN']))
$boot2 = New-ScheduledTaskTrigger -AtStartup; $boot2.Delay = 'PT2M'
Register 'OpenClawOps-Supervisor' (New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$repo\windows\supervisor\Supervisor.ps1`"" -WorkingDirectory $repo) @($every, $boot2) 30

$t = [datetime]::ParseExact($site['BACKUP_NIGHTLY_TIME'], 'HH:mm', $null)
Register 'OpenClawOps-BackupNightly' (New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$repo\windows\backup\Backup-OpenClaw.ps1`"" -WorkingDirectory $repo) @((New-ScheduledTaskTrigger -Daily -At $t)) 60
$t2 = [datetime]::ParseExact($site['WSL_EXPORT_TIME'], 'HH:mm', $null)
Register 'OpenClawOps-WslExportWeekly' (New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$repo\windows\backup\Export-Wsl.ps1`"" -WorkingDirectory $repo) @((New-ScheduledTaskTrigger -Weekly -DaysOfWeek $site['WSL_EXPORT_DAY'] -At $t2)) 120
$pw = $null; $cred = $null

foreach ($n in 'OpenClawOps-WSLBoot', 'OpenClawOps-Supervisor', 'OpenClawOps-BackupNightly', 'OpenClawOps-WslExportWeekly') {
    $tk = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if ($tk -and $tk.State -ne 'Disabled') { $verified += "$n registered as $($tk.Principal.UserId)" } else { $open += "$n missing/disabled" }
}
Write-OpsLog -Component tasks -Message 'Scheduled tasks registered'
# Smoke: run the supervisor once now
Start-ScheduledTask -TaskName 'OpenClawOps-Supervisor'; Start-Sleep 20
$last = (Get-ScheduledTaskInfo -TaskName 'OpenClawOps-Supervisor').LastTaskResult
if ($last -eq 0 -or $last -eq 267009) { $verified += "supervisor ran (result $last)" } else { $open += "supervisor smoke run returned $last - check logs\ops.log" }
Write-PhaseResult -Phase 4 -Pass $false -Changed $changed -Verified $verified -Open ($open + @('Phase 4 gate: .\windows\90-verify.ps1 -Phase 4 then the live reboot test (RUNBOOK)'))
