<#
.SYNOPSIS
    Create a Desktop shortcut for the STALKER GAMMA Save Backup app.

.DESCRIPTION
    Generates a proper Windows .lnk on YOUR Desktop, wired to this folder's
    UI script and icon. Run it once from the folder where you keep the files
    (double-click, or run it from PowerShell). It writes only the shortcut -
    it never touches your saves or config.

.EXAMPLE
    .\Create-Desktop-Shortcut.ps1
#>
[CmdletBinding()]
param(
    # Where to put the shortcut. Defaults to your Desktop.
    [string]$Destination = [Environment]::GetFolderPath('Desktop')
)

$ErrorActionPreference = 'Stop'

$here   = $PSScriptRoot
$uiPath = Join-Path $here 'stalker-gamma-backup-ui.ps1'
$icoPath = Join-Path $here 'stalker-gamma-backup.ico'

if (-not (Test-Path -LiteralPath $uiPath)) {
    throw "Could not find stalker-gamma-backup-ui.ps1 next to this script. Run it from the app folder."
}

$lnkPath = Join-Path $Destination 'STALKER GAMMA Save Backup.lnk'

$shell    = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath       = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
$shortcut.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uiPath`""
$shortcut.WorkingDirectory = $here
$shortcut.Description       = 'STALKER GAMMA Save Backup'
if (Test-Path -LiteralPath $icoPath) { $shortcut.IconLocation = $icoPath }
$shortcut.Save()

Write-Host ''
Write-Host "Created shortcut:" -ForegroundColor Green
Write-Host "  $lnkPath"
Write-Host ''
Write-Host "Double-click it on your Desktop to launch the app." -ForegroundColor Cyan
