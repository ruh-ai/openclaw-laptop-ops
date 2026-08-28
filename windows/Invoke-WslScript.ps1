<# Run a repo script inside WSL as WSL_USER (or root), with the repo mounted. Prints output, exits with the script's code.
   Usage: .\windows\Invoke-WslScript.ps1 -Script wsl/healthcheck.sh [-Args a,b] [-AsRoot] #>
param([Parameter(Mandatory)][string]$Script, [string[]]$Args = @(), [switch]$AsRoot, [int]$TimeoutSec = 900)
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Import-SiteConfig | Out-Null
$r = Invoke-WslScript -Script $Script -Arguments $Args -AsRoot:$AsRoot -TimeoutSec $TimeoutSec
Write-Output $r.Output
exit $r.ExitCode
