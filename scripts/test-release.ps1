<#
.SYNOPSIS
    Runs safe release-readiness tests against temporary fake save folders.
.DESCRIPTION
    Dependency-free smoke tests for the backup engine. The script creates only
    throwaway folders under the system temp directory, writes fake save files,
    and verifies the engine never modifies those source files. It also exercises
    logical-save grouping, rolling replacement, minute-precision names and one-zip
    -per-save behavior. No real STALKER saves are ever used.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$enginePath = Join-Path $repoRoot 'backup-stalker-gamma-saves.ps1'
$uiPath = Join-Path $repoRoot 'stalker-gamma-backup-ui.ps1'
$exampleConfigPath = Join-Path $repoRoot 'stalker-gamma-backup-config.example.json'

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

# Create one logical save in the live folder: <Name>.scop + <Name>.scoc, plus an
# optional <Name>.dds thumbnail. Use the switches to simulate partial / pair-only
# saves.
function New-LiveSave {
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $Name,
        [string] $Content = 'state',
        [switch] $NoScop,
        [switch] $NoScoc,
        [switch] $Dds
    )
    if (-not $NoScop) { Set-Content -LiteralPath (Join-Path $Folder "$Name.scop") -Value "$Content-scop" -Encoding ASCII }
    if (-not $NoScoc) { Set-Content -LiteralPath (Join-Path $Folder "$Name.scoc") -Value "$Content-scoc" -Encoding ASCII }
    if ($Dds)         { Set-Content -LiteralPath (Join-Path $Folder "$Name.dds")  -Value "$Content-dds"  -Encoding ASCII }
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

# Write a plain (non-zip) rolling/milestone restore point directly into a folder.
function New-RollingRestorePoint {
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $SaveName,
        [Parameter(Mandatory)] [string] $Timestamp,
        [string] $CollisionSuffix = '',
        [switch] $Thumbnail
    )
    $suffix = if ($CollisionSuffix) { "__$CollisionSuffix" } else { '' }
    foreach ($ext in @('.scop', '.scoc')) {
        $name = "{0}__{1}{2}{3}" -f $SaveName, $Timestamp, $suffix, $ext
        Set-Content -LiteralPath (Join-Path $Folder $name) -Value "$SaveName-$Timestamp-$ext" -Encoding ASCII
    }
    if ($Thumbnail) {
        $name = "{0}__{1}{2}.dds" -f $SaveName, $Timestamp, $suffix
        Set-Content -LiteralPath (Join-Path $Folder $name) -Value "$SaveName-$Timestamp-dds" -Encoding ASCII
    }
}

# Write a grouped-zip restore point (one .zip holding .scop + .scoc + optional
# .dds) using the engine's own group zip writer, the same way real backups do.
function New-GroupedZipRestorePoint {
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $SaveName,
        [Parameter(Mandatory)] [string] $Timestamp,
        [switch] $Thumbnail
    )
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sgb-zip-src-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $sources = @()
        foreach ($ext in @('.scop', '.scoc')) {
            $p = Join-Path $tmp "$SaveName$ext"
            Set-Content -LiteralPath $p -Value "$SaveName-$ext" -Encoding ASCII
            $sources += $p
        }
        if ($Thumbnail) {
            $p = Join-Path $tmp "$SaveName.dds"
            Set-Content -LiteralPath $p -Value "$SaveName-dds" -Encoding ASCII
            $sources += $p
        }
        $zipPath = Join-Path $Folder ("{0}__{1}.zip" -f $SaveName, $Timestamp)
        New-ZipBackupGroup -Sources $sources -DestinationZip $zipPath | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-BytesHash {
    param([Parameter(Mandatory)] [string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# Pick a single logical save group out of a Get-LiveSaveGroups result by name.
function Get-PointBaseName {
    param($Groups, [Parameter(Mandatory)] [string] $SaveName)
    $match = @($Groups | Where-Object { $_.SaveName -eq $SaveName })
    if ($match.Count -eq 0) { throw "Live save group not found for '$SaveName'." }
    return $match[0]
}

# Run a block with Get-Date pinned to a fixed moment so backups land on a known,
# controllable minute (lets a test prove replacement across two distinct minutes).
function Use-FixedNow {
    param(
        [Parameter(Mandatory)] [datetime] $When,
        [Parameter(Mandatory)] [scriptblock] $Body
    )
    $script:FixedNow = $When
    function Get-Date {
        param([string] $Format)
        if ($Format) { return $script:FixedNow.ToString($Format, [Globalization.CultureInfo]::InvariantCulture) }
        return $script:FixedNow
    }
    try { & $Body }
    finally { Remove-Item -LiteralPath 'Function:\Get-Date' -ErrorAction SilentlyContinue }
}

try {
    # -------------------------------------------------------------------------
    # Logical-save grouping & completeness (live savedgames folder)
    # -------------------------------------------------------------------------
    Invoke-Test 'live quicksave .scop + .scoc + .dds is one complete logical save' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'quicksave' -Dds
        $groups = @(Get-LiveSaveGroups -Folder $cfg.saveFolderPath)
        Assert-Equal 1 $groups.Count 'Expected one logical save group.'
        Assert-Equal 'quicksave' $groups[0].SaveName 'Group save name mismatch.'
        Assert-True $groups[0].IsComplete 'Complete trio was not detected as complete.'
        Assert-Equal 3 @($groups[0].Files).Count 'Expected three grouped files.'
    }

    Invoke-Test 'live autosave .scop + .scoc + .dds is one complete logical save' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'autosave' -Dds
        $groups = @(Get-LiveSaveGroups -Folder $cfg.saveFolderPath)
        Assert-Equal 1 $groups.Count 'Expected one logical save group.'
        Assert-True ((Get-PointBaseName $groups 'autosave').IsComplete) 'autosave trio was not complete.'
    }

    Invoke-Test 'live sleep .scop + .scoc + .dds is one complete logical save' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'sleep' -Dds
        $groups = @(Get-LiveSaveGroups -Folder $cfg.saveFolderPath)
        Assert-Equal 1 $groups.Count 'Expected one logical save group.'
        Assert-True ((Get-PointBaseName $groups 'sleep').IsComplete) 'sleep trio was not complete.'
    }

    Invoke-Test 'manual save with custom base name (with spaces) is one complete logical save' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'my hardcore run_02' -Dds
        $groups = @(Get-LiveSaveGroups -Folder $cfg.saveFolderPath)
        Assert-Equal 1 $groups.Count 'Custom-named save was not grouped as one logical save.'
        Assert-Equal 'my hardcore run_02' $groups[0].SaveName 'Custom save name parsed incorrectly.'
        Assert-True $groups[0].IsComplete 'Custom-named complete save was not complete.'
    }

    Invoke-Test 'missing .scoc or .scop is detected as incomplete' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'noscoc' -NoScoc
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'noscop' -NoScop
        $groups = @(Get-LiveSaveGroups -Folder $cfg.saveFolderPath)
        Assert-True (-not (Get-PointBaseName $groups 'noscoc').IsComplete) 'Missing .scoc should be incomplete.'
        Assert-True (-not (Get-PointBaseName $groups 'noscop').IsComplete) 'Missing .scop should be incomplete.'
    }

    Invoke-Test 'missing .dds does not make a save incomplete' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'pawnly'
        $groups = @(Get-LiveSaveGroups -Folder $cfg.saveFolderPath)
        Assert-True $groups[0].IsComplete 'A .scop + .scoc pair without .dds should still be complete.'
        Assert-Equal 2 @($groups[0].Files).Count 'Expected two files when the optional thumbnail is absent.'
    }

    # -------------------------------------------------------------------------
    # Backup behavior (grouping, replacement, minute precision)
    # -------------------------------------------------------------------------
    Invoke-Test 'one-time backup writes one grouped restore point and leaves originals unchanged' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'quicksave' -Dds -Content 'alive'
        $beforeScop = Get-BytesHash (Join-Path $cfg.saveFolderPath 'quicksave.scop')

        Invoke-BackupAll

        $backups = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File)
        Assert-Equal 3 $backups.Count 'Expected the .scop + .scoc + .dds group to be backed up together.'
        $stamps = @($backups | ForEach-Object { ($_.Name -replace '^quicksave__', '') -replace '\.(scop|scoc|dds)$', '' } | Select-Object -Unique)
        Assert-Equal 1 $stamps.Count 'Group files should share one timestamp so they form a single restore point.'
        Assert-Equal $beforeScop (Get-BytesHash (Join-Path $cfg.saveFolderPath 'quicksave.scop')) 'Original fake save changed.'
    }

    Invoke-Test 'rolling backup filenames use minute precision (no seconds)' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'quicksave' -Dds
        Invoke-BackupAll
        $backups = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File)
        foreach ($file in $backups) {
            Assert-True ($file.Name -match '^quicksave__\d{4}-\d{2}-\d{2}_\d{2}-\d{2}\.(scop|scoc|dds)$') ("Backup name should be minute precision without seconds: $($file.Name)")
        }
    }

    Invoke-Test 'incomplete live save is not backed up (never replaces a complete backup with a partial write)' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'half' -NoScoc
        Invoke-BackupAll
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File).Count 'A partial (missing .scoc) save must not be backed up.'
    }

    Invoke-Test 'normal rolling backup replaces the previous backup with the same logical save name' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'quicksave' -Dds -Content 'first'
        Use-FixedNow -When ([datetime]'2026-06-04T22:30:10') -Body { Invoke-BackupGroup -SaveName 'quicksave' }

        New-LiveSave -Folder $cfg.saveFolderPath -Name 'quicksave' -Dds -Content 'second'
        Use-FixedNow -When ([datetime]'2026-06-04T22:31:10') -Body { Invoke-BackupGroup -SaveName 'quicksave' }

        $all = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File)
        Assert-Equal 3 $all.Count 'Replacement should keep exactly one restore point (the newest) per save name.'
        Assert-Equal 0 @($all | Where-Object { $_.Name -like '*22-30*' }).Count 'The previous minute backup should have been replaced.'
        Assert-Equal 3 @($all | Where-Object { $_.Name -like '*22-31*' }).Count 'The newest backup should remain.'
        Assert-True ((Get-Content -LiteralPath (Join-Path $cfg.backupFolderPath 'quicksave__2026-06-04_22-31.scop') -Raw) -like '*second*') 'Newest backup did not match the changed source.'
    }

    Invoke-Test 'rolling replacement never touches live saves, milestones, safety backups, or outside files' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        $root = Split-Path -Parent $cfg.saveFolderPath
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'quicksave' -Dds -Content 'live'
        $liveHash = Get-BytesHash (Join-Path $cfg.saveFolderPath 'quicksave.scop')

        # A previous rolling backup that should be replaced.
        New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_00-00'
        # A milestone, a pre-restore safety backup, and an out-of-scope folder that must all survive.
        New-Item -ItemType Directory -Path $cfg.milestoneFolderPath -Force | Out-Null
        New-RollingRestorePoint -Folder $cfg.milestoneFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_00-00-00'
        $safetyRoot = Join-Path $cfg.backupFolderPath 'PreRestoreSafetyBackups'
        New-Item -ItemType Directory -Path $safetyRoot -Force | Out-Null
        New-RollingRestorePoint -Folder $safetyRoot -SaveName 'quicksave' -Timestamp '2026-06-04_00-00-00'
        $outside = Join-Path $root 'outside-backups'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        New-RollingRestorePoint -Folder $outside -SaveName 'quicksave' -Timestamp '2026-06-04_00-00-00'

        Use-FixedNow -When ([datetime]'2026-06-04T23:00:10') -Body { Invoke-BackupGroup -SaveName 'quicksave' }

        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like '*00-00.scop' }).Count 'Old rolling backup was not replaced.'
        Assert-Equal 3 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like '*23-00*' }).Count 'New rolling backup is missing.'
        Assert-Equal 2 @(Get-ChildItem -LiteralPath $cfg.milestoneFolderPath -File).Count 'Milestone backup was touched by rolling replacement.'
        Assert-Equal 2 @(Get-ChildItem -LiteralPath $safetyRoot -File).Count 'Pre-restore safety backup was touched by rolling replacement.'
        Assert-Equal 2 @(Get-ChildItem -LiteralPath $outside -File).Count 'A file outside the backup folder was touched.'
        Assert-Equal $liveHash (Get-BytesHash (Join-Path $cfg.saveFolderPath 'quicksave.scop')) 'Live save changed during rolling backup.'
    }

    Invoke-Test 'zip mode stores each complete save group as ONE zip' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot) -Zip $true
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'quicksave' -Dds
        Invoke-BackupAll

        $zips = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File)
        Assert-Equal 1 $zips.Count 'Expected exactly one zip for the whole save group.'
        Assert-True ($zips[0].Name -match '^quicksave__\d{4}-\d{2}-\d{2}_\d{2}-\d{2}\.zip$') ("Zip name should represent the logical save without seconds: $($zips[0].Name)")
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zips[0].FullName)
        try {
            $entries = @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object)
            Assert-Equal 3 $entries.Count 'Zip should contain the .scop + .scoc + .dds of the save.'
            Assert-True ($entries -contains 'quicksave.scop') 'Zip is missing quicksave.scop.'
            Assert-True ($entries -contains 'quicksave.scoc') 'Zip is missing quicksave.scoc.'
            Assert-True ($entries -contains 'quicksave.dds') 'Zip is missing quicksave.dds.'
        }
        finally {
            $zip.Dispose()
        }
    }

    Invoke-Test 'zip rolling backup replaces the previous zip for the same save name' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot) -Zip $true
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'autosave' -Content 'first'
        Use-FixedNow -When ([datetime]'2026-06-04T10:00:10') -Body { Invoke-BackupGroup -SaveName 'autosave' }
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'autosave' -Content 'second'
        Use-FixedNow -When ([datetime]'2026-06-04T10:05:10') -Body { Invoke-BackupGroup -SaveName 'autosave' }

        $zips = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File)
        Assert-Equal 1 $zips.Count 'Zip replacement should leave exactly one zip per save name (no mixed old/new).'
        Assert-True ($zips[0].Name -like '*10-05.zip') 'The newest zip should remain after replacement.'
    }

    Invoke-Test 'include extensions are respected' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot) -Extensions @('.scop')
        New-FakeSave -Folder $cfg.saveFolderPath -Name 'included.scop' -Content 'save' | Out-Null
        New-FakeSave -Folder $cfg.saveFolderPath -Name 'ignored.txt' -Content 'ignore' | Out-Null

        Invoke-BackupAll

        Assert-Equal 1 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File).Count 'Expected only the included extension to be backed up.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -Filter '*.txt' -File).Count 'Unexpected backup for excluded extension.'
    }

    Invoke-Test 'missing backup target is handled without changing originals' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        $root = Split-Path -Parent $cfg.saveFolderPath
        New-LiveSave -Folder $cfg.saveFolderPath -Name 'quicksave'
        $sourceHash = Get-BytesHash (Join-Path $cfg.saveFolderPath 'quicksave.scop')
        $cfg.backupFolderPath = Join-Path (Join-Path $root 'missing-parent') 'backups'

        Invoke-BackupAll

        Assert-Equal $sourceHash (Get-BytesHash (Join-Path $cfg.saveFolderPath 'quicksave.scop')) 'Original fake save changed when backup target was missing.'
        Assert-True (Test-Path -LiteralPath $cfg.backupFolderPath -PathType Container) 'Expected local missing backup folder to be created safely.'
    }

    # -------------------------------------------------------------------------
    # Retention & collision handling
    # -------------------------------------------------------------------------
    Invoke-Test 'retention keeps the newest N logical saves and deletes only older rolling points' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot) -Keep 2
        New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_00-01' -Thumbnail
        New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'autosave'  -Timestamp '2026-06-04_00-02'
        New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'sleep'     -Timestamp '2026-06-04_00-03'

        Invoke-Retention -Base 'sleep' -Ext '.scop'

        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'quicksave__*' }).Count 'Oldest logical save should have been pruned.'
        Assert-Equal 2 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'autosave__*' }).Count 'autosave restore point should be kept whole.'
        Assert-Equal 2 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'sleep__*' }).Count 'sleep restore point should be kept whole.'
    }

    Invoke-Test 'retention groups timestamp collision suffixes with their restore point' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot) -Keep 1
        New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_00-00-01'
        New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_00-00-02' -CollisionSuffix '002' -Thumbnail

        Invoke-Retention -Base 'quicksave' -Ext '.scop'

        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'quicksave__2026-06-04_00-00-01*' }).Count 'Older restore point was not deleted.'
        Assert-Equal 3 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'quicksave__2026-06-04_00-00-02__002*' }).Count 'Collision-suffixed restore point was not kept as a complete group.'
    }

    Invoke-Test 'grouped-zip retention keeps newest restore points as whole zips' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot) -Zip $true -Keep 2
        New-GroupedZipRestorePoint -Folder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_00-01' -Thumbnail
        New-GroupedZipRestorePoint -Folder $cfg.backupFolderPath -SaveName 'autosave'  -Timestamp '2026-06-04_00-02' -Thumbnail
        New-GroupedZipRestorePoint -Folder $cfg.backupFolderPath -SaveName 'sleep'     -Timestamp '2026-06-04_00-03' -Thumbnail

        Invoke-Retention -Base 'sleep' -Ext '.scop'

        $zips = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File)
        Assert-Equal 2 $zips.Count 'Expected the two newest grouped zips to be kept.'
        Assert-Equal 0 @($zips | Where-Object { $_.Name -like 'quicksave__*' }).Count 'Oldest grouped zip should have been pruned.'
    }

    Invoke-Test 'retention skips files protected by an active restore operation' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot) -Keep 1
        New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_00-00-01'
        New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_00-00-02'
        $protected = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'quicksave__2026-06-04_00-00-01*' })) {
            $protected[[System.IO.Path]::GetFullPath($file.FullName).ToLowerInvariant()] = $true
        }
        $script:RetentionProtectedPaths = $protected
        try {
            Invoke-Retention -Base 'quicksave' -Ext '.scop'
        }
        finally {
            Remove-Variable -Name RetentionProtectedPaths -Scope Script -ErrorAction SilentlyContinue
        }

        Assert-Equal 2 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'quicksave__2026-06-04_00-00-01*' }).Count 'Active restore point files were deleted by retention.'
    }

    Invoke-Test 'unique backup names do not overwrite an existing timestamp path' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        $first = Join-Path $cfg.backupFolderPath 'quicksave__2026-06-04_22-30.scop'
        Set-Content -LiteralPath $first -Value 'existing backup' -Encoding ASCII

        $second = Get-UniqueBackupPath -DestinationPath $first

        Assert-True ($second -ne $first) 'Expected a different path when the timestamped backup already exists.'
        Assert-True ($second -like '*__002.scop') 'Expected the collision suffix to preserve the save extension.'
    }

    Invoke-Test 'milestone collision suffix keeps a whole group together' {
        $cfg = Initialize-TestConfig -Root (New-TestRoot)
        New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_22-30-00'
        $suffix = Get-UniqueGroupSuffix -DestFolder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_22-30-00' -Extensions @('.scop', '.scoc')
        Assert-Equal '__002' $suffix 'Expected a shared collision suffix for the whole group.'
    }

    # -------------------------------------------------------------------------
    # Config loading / seeding
    # -------------------------------------------------------------------------
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
        Copy-Item -LiteralPath $exampleConfigPath -Destination $example

        Initialize-ConfigIfMissing -ConfigPath $config -ExamplePath $example

        Assert-True (Test-Path -LiteralPath $config) 'Expected missing personal config to be copied from example.'
        $cfg = Import-BackupConfig -ConfigPath $config
        Assert-Equal 10 $cfg.keepMaxBackupsPerSave 'Fresh config should default to keeping 10 logical saves.'
    }

    Invoke-Test 'example config default keeps ten logical saves' {
        $cfg = Import-BackupConfig -ConfigPath $exampleConfigPath
        Assert-Equal 10 $cfg.keepMaxBackupsPerSave 'Example config should default to keeping 10 logical saves.'
    }

    Invoke-Test 'untouched old default config is treated as ten saves' {
        $root = New-TestRoot
        $config = Join-Path $root 'stalker-gamma-backup-config.json'
        Set-Content -LiteralPath $config -Encoding ASCII -Value @'
{
  "saveFolderPath": "C:\\Anomaly\\appdata\\savedgames",
  "backupFolderPath": "D:\\STALKER GAMMA Backups",
  "milestoneFolderPath": "D:\\STALKER GAMMA Backups\\Milestones",
  "includeExtensions": [".sav", ".scop", ".scoc", ".dds"],
  "backupDelaySeconds": 3,
  "keepMaxBackupsPerSave": 200,
  "enableZipBackup": false,
  "logFilePath": "D:\\STALKER GAMMA Backups\\backup-log.txt"
}
'@

        $cfg = Import-BackupConfig -ConfigPath $config
        Assert-Equal 10 $cfg.keepMaxBackupsPerSave 'Untouched old default config should be treated as 10 logical saves.'
    }

    Invoke-Test 'customized existing config keeps explicit retention value' {
        $root = New-TestRoot
        $config = Join-Path $root 'stalker-gamma-backup-config.json'
        Set-Content -LiteralPath $config -Encoding ASCII -Value @'
{
  "saveFolderPath": "C:\\Anomaly\\appdata\\savedgames",
  "backupFolderPath": "E:\\My Custom Backups",
  "milestoneFolderPath": "E:\\My Custom Backups\\Milestones",
  "includeExtensions": [".sav", ".scop", ".scoc", ".dds"],
  "backupDelaySeconds": 3,
  "keepMaxBackupsPerSave": 200,
  "enableZipBackup": false,
  "logFilePath": "E:\\My Custom Backups\\backup-log.txt"
}
'@

        $cfg = Import-BackupConfig -ConfigPath $config
        Assert-Equal 200 $cfg.keepMaxBackupsPerSave 'Customized existing config should keep an explicit retention value.'
    }

    # -------------------------------------------------------------------------
    # Branding / docs / packaging (unchanged contract)
    # -------------------------------------------------------------------------
    Invoke-Test 'main UI footer shows creator credit without visible config path' {
        $uiSource = Get-Content -LiteralPath $uiPath -Raw

        Assert-True ($uiSource -like '*Created by GAM33RSFR33AK*') 'Expected main UI source to include the creator credit.'
        Assert-True ($uiSource -like "*`$lblFootBy = New-Label 'Created by'*") 'Footer should render "Created by" as its own label.'
        Assert-True ($uiSource -like "*`$lblFootName = New-Label 'GAM33RSFR33AK'*") 'Footer should render the creator name as its own label with a visible gap.'
        Assert-True ($uiSource -notmatch '\$lblFoot\.Text\s*=.*Config:') 'Main footer should not replace the creator credit with the config path.'
        Assert-True ($uiSource -notmatch 'SetToolTip\(\$lblFoot,\s*\$script:ConfigPath\)') 'Main footer should not expose the config path tooltip.'
    }

    Invoke-Test 'UI and public docs do not describe stale 200 save-file defaults' {
        $paths = @(
            $uiPath,
            $exampleConfigPath,
            (Join-Path $repoRoot 'README.md'),
            (Join-Path $repoRoot 'CHANGELOG.md'),
            (Join-Path $repoRoot 'SECURITY.md'),
            (Join-Path $repoRoot 'docs\release-checklist.md')
        )
        $combined = ($paths | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"

        $staleKeepPattern = 'keep latest\s+' + '200'
        $staleSaveFilesPattern = '200\s+' + 'save files'
        Assert-True ($combined -notmatch $staleKeepPattern) 'Stale high-retention default text remains.'
        Assert-True ($combined -notmatch $staleSaveFilesPattern) 'Stale save-file default wording remains.'
    }

    Invoke-Test 'UI uses the Anomaly Save Guardian name, not the old product title' {
        $uiSource = Get-Content -LiteralPath $uiPath -Raw

        Assert-True ($uiSource -like "*`$form.Text            = 'Anomaly Save Guardian'*") 'Title bar should be set to Anomaly Save Guardian.'
        Assert-True ($uiSource -like "*New-Label 'ANOMALY'*") 'Header should render the ANOMALY accent label.'
        Assert-True ($uiSource -like "*New-Label 'SAVE GUARDIAN'*") 'Header should render the SAVE GUARDIAN label.'
        Assert-True ($uiSource -like '*anomaly-save-guardian.ico*') 'UI should reference the new icon asset.'
        Assert-True ($uiSource -notlike '*STALKER GAMMA Save Backup*') 'Old product title must not be used in the UI.'
        Assert-True ($uiSource -notlike "*New-Label 'SAVE BACKUP'*") 'Old SAVE BACKUP header must not be used.'
    }

    Invoke-Test 'no-console VBS launcher exists and targets the UI relative to itself' {
        $vbsPath = Join-Path $repoRoot 'Start-Anomaly-Save-Guardian.vbs'
        Assert-True (Test-Path -LiteralPath $vbsPath) 'Start-Anomaly-Save-Guardian.vbs should exist.'
        $vbs = Get-Content -LiteralPath $vbsPath -Raw

        Assert-True ($vbs -like '*stalker-gamma-backup-ui.ps1*') 'VBS launcher should reference the UI script.'
        Assert-True ($vbs -like '*GetParentFolderName*') 'VBS launcher should locate the UI relative to its own folder.'
        Assert-True ($vbs -like '*CurrentDirectory*') 'VBS launcher should set the working directory to the app folder.'
        Assert-True ($vbs -like '*-WindowStyle Hidden*') 'VBS launcher should start PowerShell with a hidden window.'
        Assert-True ($vbs -like '*-STA*') 'VBS launcher should start PowerShell in STA mode.'
        Assert-True ($vbs -like '*"""*') 'VBS launcher should quote the UI path so paths with spaces work.'
        Assert-True ($vbs -like '*shell.Run command, 0,*') 'VBS launcher should run hidden (window style 0).'
    }

    Invoke-Test 'fallback .cmd launcher and new icon asset remain available' {
        Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot 'Launch-Anomaly-Save-Guardian.cmd')) 'Fallback .cmd launcher should exist.'
        Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot 'anomaly-save-guardian.ico')) 'New app icon should exist.'
    }

    Invoke-Test 'package script ships the VBS launcher and the new zip name' {
        $pkg = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\package-release.ps1') -Raw

        Assert-True ($pkg -like '*Start-Anomaly-Save-Guardian.vbs*') 'Package should include the VBS launcher.'
        Assert-True ($pkg -like '*Launch-Anomaly-Save-Guardian.cmd*') 'Package should include the fallback .cmd launcher.'
        Assert-True ($pkg -like '*anomaly-save-guardian.ico*') 'Package should include the new icon asset.'
        Assert-True ($pkg -like '*Anomaly-Save-Guardian-v$Version.zip*') 'Package zip should use the Anomaly Save Guardian name.'
        Assert-True ($pkg -notlike '*STALKER-GAMMA-Save-Backup*') 'Package script must not reference the old zip name.'
        Assert-True ($pkg -notmatch 'git\s+tag') 'Package script must not tell v1.0.0 refreshes to create tags.'
        Assert-True ($pkg -like '*do not create or move tags*') 'Package script should document in-place v1.0.0 refresh behavior.'
    }

    Invoke-Test 'no stale STALKER-GAMMA-Save-Backup package name in docs or scripts' {
        $paths = @(
            (Join-Path $repoRoot 'README.md'),
            (Join-Path $repoRoot 'CHANGELOG.md'),
            (Join-Path $repoRoot 'CONTRIBUTING.md'),
            (Join-Path $repoRoot 'docs\release-checklist.md'),
            (Join-Path $repoRoot 'scripts\package-release.ps1')
        )
        $combined = ($paths | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"

        Assert-True ($combined -notmatch 'STALKER-GAMMA-Save-Backup') 'Stale STALKER-GAMMA-Save-Backup package name remains in docs/scripts.'
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
