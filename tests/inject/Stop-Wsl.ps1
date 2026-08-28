<# Terminate the distro (simulates WSL death). The WSLBoot task form / supervisor must bring it back. #>
Import-Module (Join-Path $PSScriptRoot '..\..\windows\lib\Common.psm1') -Force; $s = Import-SiteConfig
& wsl.exe --terminate $s['DISTRO']; Write-Host "terminated $($s['DISTRO']) at $(Get-Date -Format T). Watch: .\windows\90-verify.ps1 -Phase 2 -Watch"
