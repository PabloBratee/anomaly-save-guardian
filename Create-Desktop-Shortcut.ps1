<#
.SYNOPSIS
    Create a Desktop shortcut for Anomaly Save Guardian.

.DESCRIPTION
    Generates a proper Windows .lnk on YOUR Desktop, wired to this folder's
    no-console launcher and icon. Run it once from the folder where you keep the
    files (double-click, or run it from PowerShell). It writes only the shortcut -
    it never touches your saves or config.

    The shortcut launches via Start-Anomaly-Save-Guardian.vbs so no PowerShell
    console window is left open. If that launcher is missing, it falls back to
    launching the UI script with a hidden PowerShell window.

.EXAMPLE
    .\Create-Desktop-Shortcut.ps1
#>
[CmdletBinding()]
param(
    # Where to put the shortcut. Defaults to your Desktop.
    [string]$Destination = [Environment]::GetFolderPath('Desktop')
)

$ErrorActionPreference = 'Stop'

$here    = $PSScriptRoot
$uiPath  = Join-Path $here 'stalker-gamma-backup-ui.ps1'
$vbsPath = Join-Path $here 'Start-Anomaly-Save-Guardian.vbs'
$icoPath = Join-Path $here 'anomaly-save-guardian.ico'

if (-not (Test-Path -LiteralPath $uiPath)) {
    throw "Could not find stalker-gamma-backup-ui.ps1 next to this script. Run it from the app folder."
}

$lnkPath = Join-Path $Destination 'Anomaly Save Guardian.lnk'

$shell    = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnkPath)

if (Test-Path -LiteralPath $vbsPath) {
    # Preferred: launch the no-console VBS launcher via wscript.exe.
    $shortcut.TargetPath = (Join-Path $env:SystemRoot 'System32\wscript.exe')
    $shortcut.Arguments  = "`"$vbsPath`""
}
else {
    # Fallback: launch the UI directly with a hidden PowerShell window.
    $shortcut.TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $shortcut.Arguments  = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$uiPath`""
}

$shortcut.WorkingDirectory = $here
$shortcut.Description       = 'Anomaly Save Guardian'
if (Test-Path -LiteralPath $icoPath) { $shortcut.IconLocation = $icoPath }
$shortcut.Save()

Write-Host ''
Write-Host "Created shortcut:" -ForegroundColor Green
Write-Host "  $lnkPath"
Write-Host ''
Write-Host "Double-click it on your Desktop to launch the app." -ForegroundColor Cyan
