<# =====================================================================================
 bootstrap.ps1 - FIRST thing to run on the laptop (elevated PowerShell). Idempotent.
   1. winget: Git, Node LTS (needed for codex/claude CLIs and OpenClaw tooling)
   2. Clone/refresh this repo to REPO_DIR_WIN (public repo: anonymous clone; falls back to a PAT prompt for private forks)
   3. Create %OPS_ROOT_WIN% tree with restricted ACL
   4. Install the agent CLIs: @openai/codex and @anthropic-ai/claude-code (npm -g)
   5. Copy config\site.env.example -> config\site.env if missing
 The one-liner the human pastes (see RUNBOOK Phase 0) downloads and runs this file.
===================================================================================== #>
param(
    [string]$RepoUrl = 'https://github.com/ruh-ai/openclaw-laptop-ops.git',
    [string]$RepoDir = 'C:\openclaw-laptop-ops',
    [string]$Branch = 'main',
    [switch]$SkipAgents,
    [switch]$Private     # repo is public; pass -Private (or it auto-falls-back) if you are using a private fork
)
$ErrorActionPreference = 'Stop'
function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this in an elevated PowerShell.' }

Step 'Tooling via winget (Git, Node LTS)'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget not found. Install "App Installer" from Microsoft Store, then re-run.' }
foreach ($pkg in @('Git.Git', 'OpenJS.NodeJS.LTS')) {
    $have = winget list --id $pkg --exact 2>$null | Select-String $pkg
    if ($have) { Write-Host "  $pkg present" } else { winget install --id $pkg --exact --silent --accept-package-agreements --accept-source-agreements | Out-Null; Write-Host "  $pkg installed" }
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

Step "Repository -> $RepoDir"
if (Test-Path (Join-Path $RepoDir '.git')) {
    git -C $RepoDir fetch --quiet origin; git -C $RepoDir checkout --quiet $Branch; git -C $RepoDir pull --quiet --ff-only origin $Branch
    Write-Host '  refreshed'
} else {
    $cloned = $false
    if (-not $Private) {
        $env:GIT_TERMINAL_PROMPT = '0'
        git clone --quiet --branch $Branch $RepoUrl $RepoDir 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $RepoDir '.git'))) { $cloned = $true; Write-Host '  cloned (public)' }
        else { Write-Host '  anonymous clone failed - falling back to token clone' -ForegroundColor Yellow; Remove-Item $RepoDir -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
    }
    if (-not $cloned) {
        Write-Host '[HUMAN AT CONSOLE] Paste a read-only GitHub PAT (fine-grained, Contents:read on this repo). Input hidden.' -ForegroundColor Yellow
        $pat = Read-Host -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pat)
        try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        $authUrl = $RepoUrl -replace '^https://', "https://x-access-token:$plain@"
        git clone --quiet --branch $Branch $authUrl $RepoDir
        $plain = $null
        if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
        # strip the token from the stored remote; future pulls prompt via Git Credential Manager or re-run bootstrap
        git -C $RepoDir remote set-url origin $RepoUrl
        Write-Host '  cloned (token removed from remote URL)'
    }
}
git -C $RepoDir config core.autocrlf false | Out-Null

Step 'Ops root'
Import-Module (Join-Path $RepoDir 'windows\lib\Common.psm1') -Force
$site = Import-SiteConfig -AllowExample
$site['REPO_DIR_WIN'] = $RepoDir
Initialize-OpsRoot -Site $site | Out-Null
Write-Host "  $($site['OPS_ROOT_WIN']) ready"

if (-not $SkipAgents) {
    Step 'Agent CLIs (codex, claude)'
    foreach ($pkg in @('@openai/codex', '@anthropic-ai/claude-code')) {
        $name = ($pkg -split '/')[-1]
        if (Get-Command $name -ErrorAction SilentlyContinue) { Write-Host "  $name present" } else { npm install -g $pkg --silent 2>$null | Out-Null; Write-Host "  $pkg installed" }
    }
}

Step 'site.env'
$siteEnv = Join-Path $RepoDir 'config\site.env'
if (-not (Test-Path $siteEnv)) { Copy-Item (Join-Path $RepoDir 'config\site.env.example') $siteEnv; Write-Host '  created from example - Phase 0 fills it in' } else { Write-Host '  exists' }

Write-Host "`nBootstrap complete. Next:" -ForegroundColor Green
Write-Host "  cd $RepoDir"
Write-Host '  codex     # or: claude'
Write-Host '  > Read AGENTS.md and RUNBOOK.md. Start Phase 0.'
