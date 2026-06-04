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

function New-RollingRestorePoint {
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $SaveName,
        [Parameter(Mandatory)] [string] $Timestamp,
        [string] $CollisionSuffix = '',
        [switch] $Zip,
        [switch] $Thumbnail
    )
    $suffix = if ($CollisionSuffix) { "__$CollisionSuffix" } else { '' }
    foreach ($ext in @('.scop', '.scoc')) {
        $name = "{0}__{1}{2}{3}" -f $SaveName, $Timestamp, $suffix, $ext
        if ($Zip) { $name = "$name.zip" }
        Set-Content -LiteralPath (Join-Path $Folder $name) -Value "$SaveName-$Timestamp-$ext" -Encoding ASCII
    }
    if ($Thumbnail) {
        $name = "{0}__{1}{2}.dds" -f $SaveName, $Timestamp, $suffix
        if ($Zip) { $name = "$name.zip" }
        Set-Content -LiteralPath (Join-Path $Folder $name) -Value "$SaveName-$Timestamp-dds" -Encoding ASCII
    }
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

    Invoke-Test 'retention keeps newest ten grouped rolling restore points total with thumbnails' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root -Keep 10
        $liveScope = New-FakeSave -Folder $cfg.saveFolderPath -Name 'quicksave.scop' -Content 'live-scope'
        $liveScoc = New-FakeSave -Folder $cfg.saveFolderPath -Name 'quicksave.scoc' -Content 'live-scoc'
        $liveScopeHash = Get-BytesHash $liveScope
        $liveScocHash = Get-BytesHash $liveScoc
        New-Item -ItemType Directory -Path $cfg.milestoneFolderPath -Force | Out-Null
        New-RollingRestorePoint -Folder $cfg.milestoneFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_00-00-00' -Thumbnail
        $safetyRoot = Join-Path $cfg.backupFolderPath 'PreRestoreSafetyBackups'
        New-Item -ItemType Directory -Path $safetyRoot -Force | Out-Null
        New-RollingRestorePoint -Folder $safetyRoot -SaveName 'quicksave' -Timestamp '2026-06-04_00-00-00'
        $outside = Join-Path $root 'outside-backups'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        New-RollingRestorePoint -Folder $outside -SaveName 'quicksave' -Timestamp '2026-06-04_00-00-00'

        for ($i = 1; $i -le 12; $i++) {
            New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp ("2026-06-04_00-00-{0:D2}" -f $i) -Thumbnail
        }
        New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'autosave' -Timestamp '2026-06-04_00-01-00'

        Invoke-Retention -Base 'quicksave' -Ext '.scop'

        $quicksaveRolling = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'quicksave__*' })
        $oldest = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'quicksave__2026-06-04_00-00-01*' -or $_.Name -like 'quicksave__2026-06-04_00-00-02*' -or $_.Name -like 'quicksave__2026-06-04_00-00-03*' })
        $newest = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'quicksave__2026-06-04_00-00-12*' })
        Assert-Equal 27 $quicksaveRolling.Count 'Expected nine quicksave restore points with .scop, .scoc and .dds files kept.'
        Assert-Equal 0 $oldest.Count 'Expected the three oldest rolling restore points to be deleted as complete groups.'
        Assert-Equal 3 $newest.Count 'Expected newest restore point to keep .scop, .scoc and .dds together.'
        Assert-Equal 2 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'autosave__*' }).Count 'Retention for quicksave deleted an unrelated rolling restore point.'
        Assert-Equal 3 @(Get-ChildItem -LiteralPath $cfg.milestoneFolderPath -File).Count 'Milestone restore point was counted or deleted by rolling retention.'
        Assert-Equal 2 @(Get-ChildItem -LiteralPath $safetyRoot -File).Count 'Pre-restore safety backup was counted or deleted by rolling retention.'
        Assert-Equal 2 @(Get-ChildItem -LiteralPath $outside -File).Count 'Retention deleted files outside the configured rolling backup folder.'
        Assert-Equal $liveScopeHash (Get-BytesHash $liveScope) 'Live .scop changed during retention.'
        Assert-Equal $liveScocHash (Get-BytesHash $liveScoc) 'Live .scoc changed during retention.'
    }

    Invoke-Test 'retention groups timestamp collision suffixes with their restore point' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root -Keep 1
        New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_00-00-01'
        New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp '2026-06-04_00-00-02' -CollisionSuffix '002' -Thumbnail

        Invoke-Retention -Base 'quicksave' -Ext '.scop'

        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'quicksave__2026-06-04_00-00-01*' }).Count 'Older restore point was not deleted.'
        Assert-Equal 3 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'quicksave__2026-06-04_00-00-02__002*' }).Count 'Collision-suffixed restore point was not kept as a complete group.'
    }

    Invoke-Test 'zip retention keeps newest grouped rolling restore points' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root -Zip $true -Keep 2
        foreach ($stamp in @('2026-06-04_00-00-01', '2026-06-04_00-00-02', '2026-06-04_00-00-03')) {
            New-RollingRestorePoint -Folder $cfg.backupFolderPath -SaveName 'quicksave' -Timestamp $stamp -Zip -Thumbnail
        }

        Invoke-Retention -Base 'quicksave' -Ext '.scop'

        $zips = @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'quicksave__*.zip' })
        Assert-Equal 6 $zips.Count 'Expected two zip restore points with .scop, .scoc and .dds files kept.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.backupFolderPath -File | Where-Object { $_.Name -like 'quicksave__2026-06-04_00-00-01*' }).Count 'Oldest zip restore point was not deleted as a complete group.'
    }

    Invoke-Test 'retention skips files protected by an active restore operation' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root -Keep 1
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
        Copy-Item -LiteralPath $exampleConfigPath -Destination $example

        Initialize-ConfigIfMissing -ConfigPath $config -ExamplePath $example

        Assert-True (Test-Path -LiteralPath $config) 'Expected missing personal config to be copied from example.'
        $cfg = Import-BackupConfig -ConfigPath $config
        Assert-Equal 10 $cfg.keepMaxBackupsPerSave 'Fresh config should default to 10 grouped restore points.'
    }

    Invoke-Test 'example config default keeps ten grouped restore points' {
        $cfg = Import-BackupConfig -ConfigPath $exampleConfigPath

        Assert-Equal 10 $cfg.keepMaxBackupsPerSave 'Example config should default to 10 grouped restore points.'
    }

    Invoke-Test 'untouched old default config is treated as ten restore points' {
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

        Assert-Equal 10 $cfg.keepMaxBackupsPerSave 'Untouched old default config should be treated as 10 grouped restore points.'
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
