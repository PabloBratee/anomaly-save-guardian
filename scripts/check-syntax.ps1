<#
.SYNOPSIS
    Parse-checks every .ps1 file in the repo (PowerShell AST parser).
.DESCRIPTION
    A tiny developer/CI helper. Walks the repo for *.ps1 files and reports any
    syntax (parse) errors. Exits non-zero if any file fails to parse so it can
    be used as a pre-commit / CI gate. Does not execute any of the scripts.
#>
[CmdletBinding()]
param()

$repoRoot = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter *.ps1 -File |
    Where-Object { $_.FullName -notmatch '\\\.git\\' }

$failed = 0
foreach ($file in $files) {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        $failed++
        Write-Host ("FAIL  {0}" -f $file.FullName) -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host ("      line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
        }
    }
    else {
        Write-Host ("OK    {0}" -f $file.Name) -ForegroundColor Green
    }
}

Write-Host ''
if ($failed -gt 0) {
    Write-Host ("{0} file(s) failed to parse." -f $failed) -ForegroundColor Red
    exit 1
}
Write-Host 'All PowerShell files parsed cleanly.' -ForegroundColor Green
