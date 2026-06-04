<#
.SYNOPSIS
    Verifies the UI refuses to start when another instance owns the app mutex.
.DESCRIPTION
    Uses a temporary helper PowerShell process to hold the same named mutex the
    UI uses, then launches the UI with -NoShow and confirms it exits cleanly
    with the duplicate-instance message. No real save folders are used.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$uiPath = Join-Path $repoRoot 'stalker-gamma-backup-ui.ps1'
$mutexName = 'Global\AnomalySaveGuardian_GAM33RSFR33AK'
$expectedMessage = 'Anomaly Save Guardian is already running. Check the system tray.'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("asg-ui-single-instance-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$holderScript = Join-Path $tempRoot 'hold-mutex.ps1'
$readyFile = Join-Path $tempRoot 'ready.txt'
$outFile = Join-Path $tempRoot 'ui-out.txt'
$errFile = Join-Path $tempRoot 'ui-err.txt'

Set-Content -LiteralPath $holderScript -Encoding ASCII -Value @"
`$ErrorActionPreference = 'Stop'
`$mutex = New-Object System.Threading.Mutex(`$false, '$mutexName')
`$hasHandle = `$false
try {
    `$hasHandle = `$mutex.WaitOne(0, `$false)
    if (-not `$hasHandle) { throw 'Could not acquire test mutex.' }
    Set-Content -LiteralPath '$readyFile' -Value 'ready' -Encoding ASCII
    Start-Sleep -Seconds 20
}
finally {
    if (`$hasHandle) { `$mutex.ReleaseMutex() }
    `$mutex.Dispose()
}
"@

$holder = $null
try {
    $holder = Start-Process -FilePath powershell.exe -ArgumentList @(
        '-STA',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $holderScript
    ) -PassThru -WindowStyle Hidden

    $deadline = (Get-Date).AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyFile)) {
        if ($holder.HasExited) { throw "Mutex holder exited early with code $($holder.ExitCode)." }
        if ((Get-Date) -gt $deadline) { throw 'Timed out waiting for mutex holder.' }
        Start-Sleep -Milliseconds 100
    }

    $ui = Start-Process -FilePath powershell.exe -ArgumentList @(
        '-STA',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $uiPath,
        '-NoShow'
    ) -PassThru -Wait -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $stdout = if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw } else { '' }

    if ($ui.ExitCode -ne 0) {
        throw "Expected duplicate UI launch to exit with code 0; got $($ui.ExitCode). stderr: $stderr"
    }
    if ($stdout -notlike "*$expectedMessage*") {
        throw "Expected duplicate UI message not found. stdout: $stdout stderr: $stderr"
    }

    Write-Host 'PASS  duplicate UI launch exits cleanly with single-instance message' -ForegroundColor Green
}
finally {
    if ($holder -and -not $holder.HasExited) {
        Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
        $holder.WaitForExit()
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
