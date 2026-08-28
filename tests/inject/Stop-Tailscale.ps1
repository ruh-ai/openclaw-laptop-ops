<# Stops the Tailscale Windows service to test service-recovery restart. THIS TOUCHES A PROTECTED COMPONENT — only run with a human at the
   console and TeamViewer connected; you will lose SSH-over-Tailscale until it restarts (~5s via sc failure actions, or Start-Service). #>
param([switch]$IUnderstandThisCutsRemoteAccess)
if (-not $IUnderstandThisCutsRemoteAccess) { throw 'Re-run with -IUnderstandThisCutsRemoteAccess (human decision).' }
Stop-Service Tailscale -Force; Write-Host "Tailscale stopped at $(Get-Date -Format T). Expected: auto-restart via service recovery within ~10s. Check: Get-Service Tailscale"
Start-Sleep 15; Get-Service Tailscale | Format-Table Status, StartType -AutoSize
if ((Get-Service Tailscale).Status -ne 'Running') { Start-Service Tailscale; Write-Warning 'Service recovery did NOT restart it — started manually. Check: sc qfailure Tailscale' }
