<# Weekly full WSL distro export (recoverable image). Verifies the tar lists and is non-trivial before pruning older exports.
   Skips + Slack when free space < MIN_FREE_GB_FOR_EXPORT. Export runs while the distro is live (supported), ~minutes. #>
Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force
$site = Import-SiteConfig; Initialize-OpsRoot | Out-Null
$dir = Join-Path $site['OPS_ROOT_WIN'] 'backups\wsl-export'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
$free = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
if ($free -lt [int]$site['MIN_FREE_GB_FOR_EXPORT']) { Write-OpsLog -Level WARN -Component export -Message "only $free GB free — export skipped"; Send-OpsSlack -Title 'WSL export skipped: low disk' -Text "$free GB free on C:" -Severity warning | Out-Null; exit 2 }
$file = Join-Path $dir "$($site['DISTRO'])-$(Get-Date -Format yyyyMMdd-HHmm).tar"
Write-OpsLog -Component export -Message "wsl --export $($site['DISTRO']) -> $file"
& wsl.exe --export $site['DISTRO'] $file 2>&1 | Out-Null
if (-not (Test-Path $file) -or (Get-Item $file).Length -lt 100MB) { Write-OpsLog -Level ERROR -Component export -Message 'export missing or suspiciously small'; Send-OpsSlack -Title 'WSL export FAILED' -Severity danger | Out-Null; exit 1 }
# verify listable (use tar inside WSL against the Windows path)
$v = Invoke-WslBash -Command "tar -tf '$(ConvertTo-WslPath $file)' 2>/dev/null | head -50 | wc -l" -TimeoutSec 600
if ([int]($v.Output.Trim()) -lt 10) { Write-OpsLog -Level ERROR -Component export -Message 'export does not list as a tar'; exit 1 }
Get-ChildItem $dir -Filter '*.tar' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 2 | Remove-Item -Force   # keep newest 2
Write-OpsLog -Component export -Message "WSL export OK: $file ($([math]::Round((Get-Item $file).Length/1GB,2)) GB)"
Send-OpsSlack -Title 'Weekly WSL export OK' -Text "$([math]::Round((Get-Item $file).Length/1GB,2)) GB" -Severity info | Out-Null
exit 0
