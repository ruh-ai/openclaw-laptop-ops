<# Make hooks.slack.com unresolvable via hosts file (supervisor must queue and later flush). -Revert restores. #>
param([switch]$Revert)
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"; $marker = '# OpenClawOps-test-block-slack'
$c = Get-Content $hosts | Where-Object { $_ -notmatch 'OpenClawOps-test-block-slack' }
if (-not $Revert) { $c += "127.0.0.1 hooks.slack.com $marker" }
$c | Set-Content $hosts -Encoding ascii; ipconfig /flushdns | Out-Null
Write-Host $(if ($Revert) { 'Slack unblocked; run the supervisor once to flush the queue' } else { 'Slack blocked (hosts). REMEMBER: -Revert' })
