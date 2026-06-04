<#
.SYNOPSIS
    Build a clean release .zip containing only the files users need to download.

.DESCRIPTION
    Creates 'dist\STALKER-GAMMA-Save-Backup-vX.Y.Z.zip' next to the repo, holding
    just the runtime scripts, the example config, the icon and the user-facing
    docs - never your personal config, logs, backups, screenshots or git data.

    Pure built-in PowerShell / .NET - no build tools or external dependencies.
    The 'dist' folder is git-ignored.

.EXAMPLE
    .\scripts\package-release.ps1
.EXAMPLE
    .\scripts\package-release.ps1 -Version 1.2.0
#>
[CmdletBinding()]
param(
    # Override the version in the zip name. Defaults to the engine's $AppVersion.
    [string]$Version
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$enginePath = Join-Path $repoRoot 'backup-stalker-gamma-saves.ps1'

# Resolve the version from the engine unless explicitly given.
if (-not $Version) {
    $line = Select-String -LiteralPath $enginePath -Pattern "AppVersion\s*=\s*'([^']+)'" | Select-Object -First 1
    if ($line -and $line.Matches.Count -gt 0) {
        $Version = $line.Matches[0].Groups[1].Value
    }
    else {
        throw "Could not read version from $enginePath. Pass -Version explicitly."
    }
}

# The exact set of files a user needs to run the app.
$include = @(
    'backup-stalker-gamma-saves.ps1',
    'restore-stalker-gamma-saves.ps1',
    'stalker-gamma-backup-ui.ps1',
    'stalker-gamma-backup-config.example.json',
    'stalker-gamma-backup.ico',
    'Launch STALKER GAMMA Save Backup.cmd',
    'Create-Desktop-Shortcut.ps1',
    'README.md',
    'CHANGELOG.md',
    'SECURITY.md',
    'LICENSE'
)

$missing = @()
$sources = foreach ($name in $include) {
    $p = Join-Path $repoRoot $name
    if (Test-Path -LiteralPath $p) { $p } else { $missing += $name }
}
if ($missing.Count -gt 0) {
    throw ("Missing expected file(s): {0}" -f ($missing -join ', '))
}

$distDir = Join-Path $repoRoot 'dist'
if (-not (Test-Path -LiteralPath $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}

$zipName = "STALKER-GAMMA-Save-Backup-v$Version.zip"
$zipPath = Join-Path $distDir $zipName
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Compress-Archive -LiteralPath $sources -DestinationPath $zipPath -CompressionLevel Optimal

$size = '{0:N0} KB' -f ((Get-Item -LiteralPath $zipPath).Length / 1KB)
Write-Host ''
Write-Host "Created release package:" -ForegroundColor Green
Write-Host "  $zipPath  ($size)"
Write-Host ''
Write-Host "Contents:" -ForegroundColor Cyan
$include | ForEach-Object { Write-Host "  - $_" }
Write-Host ''
Write-Host "Next steps to publish a GitHub Release:" -ForegroundColor Cyan
Write-Host "  1. After final changes are on main, tag the release:"
Write-Host "       git switch main"
Write-Host "       git pull --ff-only origin main"
Write-Host "       git tag v$Version"
Write-Host "       git push origin main"
Write-Host "       git push origin v$Version"
Write-Host "  2. On GitHub: Releases -> Draft a new release -> choose tag v$Version."
Write-Host "  3. Title it 'v$Version', paste the relevant CHANGELOG section as the notes."
Write-Host "  4. Attach $zipName as a release asset, then Publish."
