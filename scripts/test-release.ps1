<#
.SYNOPSIS
    Runs safe release-readiness tests against temporary fake save folders.
.DESCRIPTION
    Dependency-free smoke tests for the backup engine. The script creates only
    throwaway folders under the system temp directory, writes fake save files,
    and verifies the engine never modifies those source files.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$enginePath = Join-Path $repoRoot 'backup-stalker-gamma-saves.ps1'

. $enginePath -AsLibrary

$script:Passed = 0
$script:Failed = 0
$script:TestRoots = @()

function Assert-True {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory)] [string] $Message)
    if ($Expected -ne $Actual) {
        throw ("{0} Expected: {1}; actual: {2}" -f $Message, $Expected, $Actual)
    }
}

function Invoke-Test {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Body
    )
    try {
        & $Body
        $script:Passed++
        Write-Host ("PASS  {0}" -f $Name) -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host ("FAIL  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("      {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function New-TestRoot {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sgb-release-test-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $script:TestRoots += $root
    return $root
}

function Initialize-TestConfig {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [bool] $Zip = $false,
        [int] $Keep = 10,
        [string[]] $Extensions = @('.scop', '.scoc', '.dds')
    )
    $save = Join-Path $Root 'savedgames'
    $backup = Join-Path $Root 'backups'
    $milestones = Join-Path $Root 'milestones'
    New-Item -ItemType Directory -Path $save, $backup -Force | Out-Null
    $script:Config = [PSCustomObject]@{
        saveFolderPath        = $save
        backupFolderPath      = $backup
        milestoneFolderPath   = $milestones
        includeExtensions     = @($Extensions | ForEach-Object { $_.ToLowerInvariant() })
        backupDelaySeconds    = 0
        keepMaxBackupsPerSave = $Keep
        enableZipBackup       = $Zip
        logFilePath           = Join-Path $Root 'backup-log.txt'
    }
    $script:BackupCache = @{}
    Set-Variable -Name DryRun -Value $false -Scope Script
    return $script:Config
}

function New-FakeSave {
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Content
    )
    $path = Join-Path $Folder $Name
    Set-Content -LiteralPath $path -Value $Content -Encoding ASCII
    return $path
}

function Get-BytesHash {
    param([Parameter(Mandatory)] [string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

try {
    Invoke-Test 'unique backup names do not overwrite an existing timestamp path' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        $first = Join-Path $cfg.backupFolderPath 'quicksave__2026-06-04_22-30-15.scop'
        Set-Content -LiteralPath $first -Value 'existing backup' -Encoding ASCII

        $second = Get-UniqueBackupPath -DestinationPath $first

        Assert-True ($second -ne $first) 'Expected a different path when the timestamped backup already exists.'
        Assert-True ($second -like '*__002.scop') 'Expected the collision suffix to preserve the save extension.'
    }

    Invoke-Test 'first backup copies fake saves and leaves originals unchanged' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        $save = New-FakeSave -Folder $cfg.saveFolderPath -Name 'quicksave.scop' -Content 'alive-state'
        $beforeHash = Get-BytesHash $save

        Invoke-BackupAll

        $afterHash = Get-BytesHash $save
        $backups = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -Filter 'quicksave__*.scop' -File)
        Assert-Equal 1 $backups.Count 'Expected exactly one backup copy.'
        Assert-Equal $beforeHash $afterHash 'Original fake save changed.'
        Assert-Equal $beforeHash (Get-BytesHash $backups[0].FullName) 'Backup content did not match source.'
    }

    Invoke-Test 'changed save creates another timestamped backup' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        $save = New-FakeSave -Folder $cfg.saveFolderPath -Name 'quicksave.scop' -Content 'state-one'

        Invoke-BackupAll
        Start-Sleep -Seconds 1
        Set-Content -LiteralPath $save -Value 'state-two' -Encoding ASCII
        $changedHash = Get-BytesHash $save
        Invoke-BackupAll

        $backups = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -Filter 'quicksave__*.scop' -File)
        Assert-Equal 2 $backups.Count 'Expected two backups after changing the fake save.'
        Assert-Equal $changedHash (Get-BytesHash (($backups | Sort-Object Name -Descending | Select-Object -First 1).FullName)) 'Newest backup did not match changed source.'
    }

    Invoke-Test 'retention deletes only old rolling backups and never originals or milestones' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root -Keep 2
        $save = New-FakeSave -Folder $cfg.saveFolderPath -Name 'quicksave.scop' -Content 'source'
        $sourceHash = Get-BytesHash $save
        New-Item -ItemType Directory -Path $cfg.milestoneFolderPath -Force | Out-Null
        $milestone = Join-Path $cfg.milestoneFolderPath 'quicksave__2026-06-04_00-00-00.scop'
        Set-Content -LiteralPath $milestone -Value 'milestone' -Encoding ASCII
        foreach ($stamp in @('2026-06-04_00-00-01', '2026-06-04_00-00-02', '2026-06-04_00-00-03')) {
            Set-Content -LiteralPath (Join-Path $cfg.backupFolderPath "quicksave__$stamp.scop") -Value $stamp -Encoding ASCII
        }

        Invoke-Retention -Base 'quicksave' -Ext '.scop'

        $rolling = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -Filter 'quicksave__*.scop' -File | Sort-Object Name)
        Assert-Equal 2 $rolling.Count 'Expected retention to keep two rolling backups.'
        Assert-True (Test-Path -LiteralPath $milestone) 'Milestone snapshot was deleted.'
        Assert-Equal $sourceHash (Get-BytesHash $save) 'Original fake save changed during retention.'
    }

    Invoke-Test 'missing backup target is handled without changing originals' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        $save = New-FakeSave -Folder $cfg.saveFolderPath -Name 'quicksave.scop' -Content 'source'
        $sourceHash = Get-BytesHash $save
        $cfg.backupFolderPath = Join-Path (Join-Path $root 'missing-parent') 'backups'

        Invoke-BackupAll

        Assert-Equal $sourceHash (Get-BytesHash $save) 'Original fake save changed when backup target was missing.'
        Assert-True (Test-Path -LiteralPath $cfg.backupFolderPath -PathType Container) 'Expected local missing backup folder to be created safely.'
    }

    Invoke-Test 'bad config and empty config fail with clear messages' {
        $root = New-TestRoot
        $bad = Join-Path $root 'bad.json'
        $empty = Join-Path $root 'empty.json'
        Set-Content -LiteralPath $bad -Value '{ "saveFolderPath": "C:\Temp" ' -Encoding ASCII
        Set-Content -LiteralPath $empty -Value '' -Encoding ASCII

        $badMessage = $null
        try { Import-BackupConfig -ConfigPath $bad | Out-Null } catch { $badMessage = $_.Exception.Message }
        $emptyMessage = $null
        try { Import-BackupConfig -ConfigPath $empty | Out-Null } catch { $emptyMessage = $_.Exception.Message }

        Assert-True ($badMessage -like '*not valid JSON*') 'Bad JSON did not produce a clear config error.'
        Assert-True ($emptyMessage -like '*is empty*') 'Empty config did not produce a clear config error.'
    }

    Invoke-Test 'missing personal config is seeded from the example template' {
        $root = New-TestRoot
        $config = Join-Path $root 'stalker-gamma-backup-config.json'
        $example = Join-Path $root 'stalker-gamma-backup-config.example.json'
        Copy-Item -LiteralPath (Join-Path $repoRoot 'stalker-gamma-backup-config.example.json') -Destination $example

        Initialize-ConfigIfMissing -ConfigPath $config -ExamplePath $example

        Assert-True (Test-Path -LiteralPath $config) 'Expected missing personal config to be copied from example.'
    }

    Invoke-Test 'include extensions are respected' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root -Extensions @('.scop')
        New-FakeSave -Folder $cfg.saveFolderPath -Name 'included.scop' -Content 'save' | Out-Null
        New-FakeSave -Folder $cfg.saveFolderPath -Name 'ignored.txt' -Content 'ignore' | Out-Null

        Invoke-BackupAll

        Assert-Equal 1 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File).Count 'Expected only one included file to be backed up.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -Filter '*.txt' -File).Count 'Unexpected backup for excluded extension.'
    }

    Invoke-Test 'zip mode creates a readable zip backup' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root -Zip $true
        New-FakeSave -Folder $cfg.saveFolderPath -Name 'quicksave.scop' -Content 'zipped-save' | Out-Null

        Invoke-BackupAll

        $zips = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -Filter 'quicksave__*.scop.zip' -File)
        Assert-Equal 1 $zips.Count 'Expected one zip backup.'
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zips[0].FullName)
        try {
            Assert-Equal 'quicksave.scop' $zip.Entries[0].FullName 'Zip entry name was not the original save filename.'
        }
        finally {
            $zip.Dispose()
        }
    }
}
finally {
    foreach ($root in $script:TestRoots) {
        if ($root -and (Test-Path -LiteralPath $root) -and $root.StartsWith([System.IO.Path]::GetTempPath())) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host ("{0} release test(s) failed; {1} passed." -f $script:Failed, $script:Passed) -ForegroundColor Red
    exit 1
}

Write-Host ("All {0} release tests passed." -f $script:Passed) -ForegroundColor Green
