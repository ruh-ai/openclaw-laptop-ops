<# Create a dummy file on C: to push usage to DISK_WARN_PCT+1 (supervisor warning; backup/export must refuse). -Cleanup removes it. #>
param([switch]$Cleanup)
Import-Module (Join-Path $PSScriptRoot '..\..\windows\lib\Common.psm1') -Force; $s = Import-SiteConfig
$f = Join-Path $s['OPS_ROOT_WIN'] 'TEST-filldisk.bin'
if ($Cleanup) { Remove-Item $f -Force -ErrorAction SilentlyContinue; Write-Host 'removed'; exit }
$c = Get-PSDrive C; $total = $c.Used + $c.Free; $target = [int64]($total * ([int]$s['DISK_WARN_PCT'] + 1) / 100) - $c.Used
if ($target -le 0) { Write-Host 'already above threshold'; exit }
& fsutil file createnew $f $target | Out-Null; Write-Host "created $([math]::Round($target/1GB,1)) GB at $f — REMEMBER: .\tests\inject\Fill-Disk.ps1 -Cleanup"
