<# Nightly application backup (also run once in Phase 4). Calls wsl/snapshot.sh --full which tars OpenClaw config,
   memory/skills/state, systemd units, ops scripts and version manifest (secrets EXCLUDED) into OPS_ROOT\backups\daily.
   Retention: BACKUP_DAILY_KEEP daily; every Sunday's copied into weekly (BACKUP_WEEKLY_KEEP). Refuses when disk > DISK_WARN_PCT. #>
Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force
$site = Import-SiteConfig; Initialize-OpsRoot | Out-Null
$c = Get-PSDrive C; $pct = [math]::Round(100 * $c.Used / ($c.Used + $c.Free))
if ($pct -ge [int]$site['DISK_WARN_PCT']) { Write-OpsLog -Level ERROR -Component backup -Message "C: at $pct% — backup skipped"; Send-OpsSlack -Title 'Backup skipped: disk space' -Text "C: $pct% used" -Severity danger | Out-Null; exit 2 }
if (-not (Test-WslRunning)) { Start-Process 'wsl.exe' -ArgumentList @('-d', $site['DISTRO'], '--exec', 'dbus-launch', 'true') -WindowStyle Hidden -Wait; Start-Sleep 10 }
$daily = Join-Path $site['OPS_ROOT_WIN'] 'backups\daily'; $weekly = Join-Path $site['OPS_ROOT_WIN'] 'backups\weekly'
$r = Invoke-WslScript -Script 'wsl/snapshot.sh' -Arguments @('--full', (ConvertTo-WslPath $daily)) -TimeoutSec 900
Write-Host $r.Output
if ($r.ExitCode -ne 0) { Write-OpsLog -Level ERROR -Component backup -Message "snapshot.sh --full failed: $($r.Output)"; Send-OpsSlack -Title 'Nightly backup FAILED' -Text ($r.Output -split "`n" | Select-Object -Last 5) -Severity danger | Out-Null; exit 1 }
$file = ($r.Output -split "`n" | Select-Object -Last 1).Trim()
$winFile = Join-Path $daily (Split-Path $file -Leaf)
if (-not (Test-Path $winFile) -or (Get-Item $winFile).Length -lt 1024) { Write-OpsLog -Level ERROR -Component backup -Message "backup file missing/empty: $winFile"; exit 1 }
# verify archive lists
$v = Invoke-WslBash -Command "tar -tzf '$file' | wc -l"; if ([int]($v.Output.Trim()) -lt 3) { Write-OpsLog -Level ERROR -Component backup -Message 'archive lists <3 entries'; exit 1 }
if ((Get-Date).DayOfWeek -eq 'Sunday') { Copy-Item $winFile (Join-Path $weekly (Split-Path $winFile -Leaf)) -Force }
Get-ChildItem $daily -Filter '*.tar.gz' | Sort-Object LastWriteTime -Descending | Select-Object -Skip ([int]$site['BACKUP_DAILY_KEEP']) | Remove-Item -Force
Get-ChildItem $weekly -Filter '*.tar.gz' | Sort-Object LastWriteTime -Descending | Select-Object -Skip ([int]$site['BACKUP_WEEKLY_KEEP']) | Remove-Item -Force
Write-OpsLog -Component backup -Message "nightly backup OK: $winFile ($([math]::Round((Get-Item $winFile).Length/1MB,1)) MB, $($v.Output.Trim()) entries)"
exit 0
