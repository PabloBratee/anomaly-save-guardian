<#
.SYNOPSIS
    Runs safe restore tests against temporary fake save folders.
.DESCRIPTION
    Dependency-free tests for guided restore behavior. The script creates only
    throwaway folders under the system temp directory and never uses real saves.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$restorePath = Join-Path $repoRoot 'restore-stalker-gamma-saves.ps1'

. $restorePath -AsLibrary

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
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sgb-restore-test-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $script:TestRoots += $root
    return $root
}

function Initialize-TestConfig {
    param([Parameter(Mandatory)] [string] $Root)
    $save = Join-Path $Root 'savedgames'
    $backup = Join-Path $Root 'backups'
    $milestones = Join-Path $Root 'milestones'
    New-Item -ItemType Directory -Path $save, $backup, $milestones -Force | Out-Null
    return [PSCustomObject]@{
        saveFolderPath        = $save
        backupFolderPath      = $backup
        milestoneFolderPath   = $milestones
        includeExtensions     = @('.scop', '.scoc', '.dds')
        backupDelaySeconds    = 0
        keepMaxBackupsPerSave = 10
        enableZipBackup       = $false
        logFilePath           = Join-Path $Root 'restore-log.txt'
    }
}

function New-FakeFile {
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

function Get-PointBySave {
    param($Points, [string] $SaveName, [string] $Type = $null)
    $matches = @($Points | Where-Object {
        $_.SaveName -eq $SaveName -and (-not $Type -or $_.Type -eq $Type)
    })
    if ($matches.Count -eq 0) { throw "Restore point not found for $SaveName / $Type" }
    return $matches[0]
}

function New-ZipFromText {
    param(
        [Parameter(Mandatory)] [string] $ZipPath,
        [Parameter(Mandatory)] [hashtable] $Entries
    )
    # The base assembly (ZipArchiveMode) is not auto-loaded on Windows PowerShell 5.1.
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sgb-zip-src-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $Entries.Keys) {
                $leaf = Split-Path -Leaf $name
                $src = Join-Path $tmp $leaf
                Set-Content -LiteralPath $src -Value ([string]$Entries[$name]) -Encoding ASCII
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $src, $name) | Out-Null
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    Invoke-Test 'discovers rolling and milestone restore points newest first' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-FakeFile $cfg.backupFolderPath 'oldsave__2026-06-04_10-00-00.scop' 'old-scope' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'oldsave__2026-06-04_10-00-00.scoc' 'old-scoc' | Out-Null
        New-FakeFile $cfg.milestoneFolderPath 'milestone_a__2026-06-04_11-00-00.scop' 'mile-scope' | Out-Null
        New-FakeFile $cfg.milestoneFolderPath 'milestone_a__2026-06-04_11-00-00.scoc' 'mile-scoc' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'newsave__2026-06-04_12-00-00.scop' 'new-scope' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'newsave__2026-06-04_12-00-00.scoc' 'new-scoc' | Out-Null

        $points = @(Get-RestorePoints -Config $cfg)

        Assert-True ($points.Count -ge 3) 'Expected rolling and milestone restore points.'
        Assert-Equal 'newsave' $points[0].SaveName 'Expected newest restore point first.'
        Assert-Equal 'Milestone' (Get-PointBySave $points 'milestone_a' 'Milestone').Type 'Milestone point was not labeled clearly.'
        Assert-Equal 'Complete' (Get-PointBySave $points 'oldsave' 'Rolling').Status 'Complete pair was not detected.'
    }

    Invoke-Test 'detects incomplete save pairs and blocks restore' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-FakeFile $cfg.backupFolderPath 'lonely__2026-06-04_13-00-00.scop' 'scope-only' | Out-Null

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'lonely' 'Rolling'
        Assert-Equal 'Missing pair' $point.Status 'Expected missing .scoc to be reported.'

        $message = $null
        try { Invoke-RestorePoint -Config $cfg -RestorePoint $point -Confirmed | Out-Null } catch { $message = $_.Exception.Message }
        Assert-True ($message -like '*complete .scop + .scoc pair*') 'Incomplete pair was not blocked before copying.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.saveFolderPath -File).Count 'Incomplete restore copied files.'
    }

    Invoke-Test 'restores complete pair and optional thumbnail with timestamp stripped' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_14-00-00.scop' 'backup-scope' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_14-00-00.scoc' 'backup-scoc' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_14-00-00.dds' 'backup-dds' | Out-Null

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'quicksave' 'Rolling'
        $result = Invoke-RestorePoint -Config $cfg -RestorePoint $point -Confirmed

        Assert-True $result.Success 'Restore result was not successful.'
        Assert-True (Test-Path -LiteralPath (Join-Path $cfg.saveFolderPath 'quicksave.scop')) 'Missing restored .scop.'
        Assert-True (Test-Path -LiteralPath (Join-Path $cfg.saveFolderPath 'quicksave.scoc')) 'Missing restored .scoc.'
        Assert-True (Test-Path -LiteralPath (Join-Path $cfg.saveFolderPath 'quicksave.dds')) 'Missing restored optional .dds.'
        Assert-Equal 'backup-scope' ((Get-Content -LiteralPath (Join-Path $cfg.saveFolderPath 'quicksave.scop') -Raw).Trim()) 'Restored .scop content mismatch.'
    }

    Invoke-Test 'strips collision suffix when restoring destination names' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-FakeFile $cfg.backupFolderPath 'autosave__2026-06-04_15-00-00__002.scop' 'scope-002' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'autosave__2026-06-04_15-00-00__002.scoc' 'scoc-002' | Out-Null

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'autosave' 'Rolling'
        Invoke-RestorePoint -Config $cfg -RestorePoint $point -Confirmed | Out-Null

        Assert-True (Test-Path -LiteralPath (Join-Path $cfg.saveFolderPath 'autosave.scop')) 'Collision suffix was not stripped from .scop destination.'
        Assert-True (Test-Path -LiteralPath (Join-Path $cfg.saveFolderPath 'autosave.scoc')) 'Collision suffix was not stripped from .scoc destination.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.saveFolderPath -Filter '*__002*' -File).Count 'Collision suffix leaked into live save folder.'
    }

    Invoke-Test 'creates pre-restore safety backup before overwriting live files' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-FakeFile $cfg.saveFolderPath 'quicksave.scop' 'live-scope' | Out-Null
        New-FakeFile $cfg.saveFolderPath 'quicksave.scoc' 'live-scoc' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_16-00-00.scop' 'backup-scope' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_16-00-00.scoc' 'backup-scoc' | Out-Null

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'quicksave' 'Rolling'
        $result = Invoke-RestorePoint -Config $cfg -RestorePoint $point -Confirmed

        Assert-True (Test-Path -LiteralPath $result.SafetyBackupFolder -PathType Container) 'Safety backup folder was not created.'
        Assert-Equal 'live-scope' ((Get-Content -LiteralPath (Join-Path $result.SafetyBackupFolder 'quicksave.scop') -Raw).Trim()) 'Original .scop was not copied to safety backup.'
        Assert-Equal 'live-scoc' ((Get-Content -LiteralPath (Join-Path $result.SafetyBackupFolder 'quicksave.scoc') -Raw).Trim()) 'Original .scoc was not copied to safety backup.'
        Assert-True (Test-Path -LiteralPath (Join-Path $result.SafetyBackupFolder 'restore-manifest.txt')) 'Safety backup manifest was not written.'
    }

    Invoke-Test 'pre-restore safety backup folders are unique for rapid repeated restores' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-FakeFile $cfg.saveFolderPath 'quicksave.scop' 'live-first-scope' | Out-Null
        New-FakeFile $cfg.saveFolderPath 'quicksave.scoc' 'live-first-scoc' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_16-30-00.scop' 'backup-scope' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_16-30-00.scoc' 'backup-scoc' | Out-Null

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'quicksave' 'Rolling'
        function Get-Date {
            param([string] $Format)
            $fixed = [datetime]'2026-06-04T16:30:30'
            if ($Format) { return $fixed.ToString($Format, [Globalization.CultureInfo]::InvariantCulture) }
            return $fixed
        }
        try {
            $first = Invoke-RestorePoint -Config $cfg -RestorePoint $point -Confirmed
            Set-Content -LiteralPath (Join-Path $cfg.saveFolderPath 'quicksave.scop') -Value 'live-second-scope' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $cfg.saveFolderPath 'quicksave.scoc') -Value 'live-second-scoc' -Encoding ASCII
            $second = Invoke-RestorePoint -Config $cfg -RestorePoint $point -Confirmed
        }
        finally {
            Remove-Item -LiteralPath 'Function:\Get-Date' -ErrorAction SilentlyContinue
        }

        Assert-True ($first.SafetyBackupFolder -ne $second.SafetyBackupFolder) 'Repeated restores reused the same safety backup folder.'
        Assert-Equal 'live-first-scope' ((Get-Content -LiteralPath (Join-Path $first.SafetyBackupFolder 'quicksave.scop') -Raw).Trim()) 'First safety backup was overwritten.'
        Assert-Equal 'live-second-scope' ((Get-Content -LiteralPath (Join-Path $second.SafetyBackupFolder 'quicksave.scop') -Raw).Trim()) 'Second safety backup did not capture the current live file.'
    }

    Invoke-Test 'cancels restore if pre-restore safety backup cannot be created' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-FakeFile $cfg.saveFolderPath 'quicksave.scop' 'live-scope' | Out-Null
        New-FakeFile $cfg.saveFolderPath 'quicksave.scoc' 'live-scoc' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'PreRestoreSafetyBackups' 'blocking-file' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_17-00-00.scop' 'backup-scope' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_17-00-00.scoc' 'backup-scoc' | Out-Null

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'quicksave' 'Rolling'
        $message = $null
        try { Invoke-RestorePoint -Config $cfg -RestorePoint $point -Confirmed | Out-Null } catch { $message = $_.Exception.Message }

        Assert-True ($message -like '*safety backup*') 'Expected safety backup failure message.'
        Assert-Equal 'live-scope' ((Get-Content -LiteralPath (Join-Path $cfg.saveFolderPath 'quicksave.scop') -Raw).Trim()) 'Live .scop changed after safety backup failure.'
        Assert-Equal 'live-scoc' ((Get-Content -LiteralPath (Join-Path $cfg.saveFolderPath 'quicksave.scoc') -Raw).Trim()) 'Live .scoc changed after safety backup failure.'
    }

    Invoke-Test 'does not delete live files or mutate backup files during restore' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-FakeFile $cfg.saveFolderPath 'other-save.scop' 'keep-me' | Out-Null
        $scope = New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_18-00-00.scop' 'backup-scope'
        $scoc = New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_18-00-00.scoc' 'backup-scoc'
        $beforeScope = Get-BytesHash $scope
        $beforeScoc = Get-BytesHash $scoc

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'quicksave' 'Rolling'
        Invoke-RestorePoint -Config $cfg -RestorePoint $point -Confirmed | Out-Null

        Assert-True (Test-Path -LiteralPath (Join-Path $cfg.saveFolderPath 'other-save.scop')) 'Unrelated live save was deleted.'
        Assert-Equal $beforeScope (Get-BytesHash $scope) 'Backup .scop changed during restore.'
        Assert-Equal $beforeScoc (Get-BytesHash $scoc) 'Backup .scoc changed during restore.'
    }

    Invoke-Test 'bad restore source paths fail safely before copying' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        $outside = New-FakeFile $root 'outside.scop' 'outside'
        $badPoint = [PSCustomObject]@{
            Id = 'bad'
            SaveName = 'bad'
            Type = 'Rolling'
            Timestamp = '2026-06-04_19-00-00'
            IsComplete = $true
            Status = 'Complete'
            Files = @(
                [PSCustomObject]@{ Extension = '.scop'; SourcePath = $outside; DestinationName = 'bad.scop'; Size = 7; IsZip = $false },
                [PSCustomObject]@{ Extension = '.scoc'; SourcePath = $outside; DestinationName = 'bad.scoc'; Size = 7; IsZip = $false }
            )
        }

        $message = $null
        try { Invoke-RestorePoint -Config $cfg -RestorePoint $badPoint -Confirmed | Out-Null } catch { $message = $_.Exception.Message }

        Assert-True ($message -like '*outside the configured backup folders*') 'Bad source path was not rejected.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.saveFolderPath -File).Count 'Bad source path copied files.'
    }

    Invoke-Test 'discovers and restores zip restore points safely' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-ZipFromText (Join-Path $cfg.backupFolderPath 'zipsave__2026-06-04_20-00-00.scop.zip') @{ 'zipsave.scop' = 'zip-scope' }
        New-ZipFromText (Join-Path $cfg.backupFolderPath 'zipsave__2026-06-04_20-00-00.scoc.zip') @{ 'zipsave.scoc' = 'zip-scoc' }

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'zipsave' 'Zip'
        $result = Invoke-RestorePoint -Config $cfg -RestorePoint $point -Confirmed

        Assert-True $result.Success 'Zip restore did not report success.'
        Assert-Equal 'zip-scope' ((Get-Content -LiteralPath (Join-Path $cfg.saveFolderPath 'zipsave.scop') -Raw).Trim()) 'Zip .scop was not restored.'
        Assert-Equal 'zip-scoc' ((Get-Content -LiteralPath (Join-Path $cfg.saveFolderPath 'zipsave.scoc') -Raw).Trim()) 'Zip .scoc was not restored.'
    }

    Invoke-Test 'blocks zip path traversal before copying anything' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-ZipFromText (Join-Path $cfg.backupFolderPath 'evil__2026-06-04_21-00-00.scop.zip') @{ '..\evil.scop' = 'evil-scope' }
        New-ZipFromText (Join-Path $cfg.backupFolderPath 'evil__2026-06-04_21-00-00.scoc.zip') @{ 'evil.scoc' = 'evil-scoc' }

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'evil' 'Zip'
        $message = $null
        try { Invoke-RestorePoint -Config $cfg -RestorePoint $point -Confirmed | Out-Null } catch { $message = $_.Exception.Message }

        Assert-True ($message -like '*unsafe zip entry*') 'Zip traversal was not rejected.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.saveFolderPath -File).Count 'Unsafe zip copied files.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'evil.scop'))) 'Zip traversal wrote outside the save folder.'
    }

    Invoke-Test 'non-zip discovery does not falsely report missing files when the whole group exists' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        # All three files share ONE timestamp, the way grouped backups now write them.
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_14-00.scop' 'scope' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_14-00.scoc' 'scoc' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_14-00.dds' 'thumb' | Out-Null

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'quicksave' 'Rolling'
        Assert-Equal 'Complete' $point.Status 'A complete .scop + .scoc (+ .dds) group must not be reported as missing.'
        Assert-Equal 3 $point.FileCount 'Expected the three group files to form one restore point.'
    }

    Invoke-Test 'discovers one grouped zip as a single complete restore point' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-ZipFromText (Join-Path $cfg.backupFolderPath 'zipgroup__2026-06-04_20-00.zip') @{
            'zipgroup.scop' = 'zip-scope'
            'zipgroup.scoc' = 'zip-scoc'
            'zipgroup.dds'  = 'zip-thumb'
        }

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'zipgroup' 'Zip'
        Assert-Equal 'Complete' $point.Status 'One zip with .scop + .scoc should be a complete restore point.'
        Assert-Equal 3 $point.FileCount 'Grouped zip should expose all three save files.'
    }

    Invoke-Test 'discovers one grouped milestone zip as a single complete restore point' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-ZipFromText (Join-Path $cfg.milestoneFolderPath 'milezip__2026-06-04_20-00.zip') @{
            'milezip.scop' = 'zip-scope'
            'milezip.scoc' = 'zip-scoc'
            'milezip.dds'  = 'zip-thumb'
        }

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'milezip' 'Milestone'
        Assert-Equal 'Milestone' $point.Type 'Grouped zip in the milestone folder should be labeled as a milestone restore point.'
        Assert-Equal 'Complete' $point.Status 'Milestone grouped zip with .scop + .scoc should be complete.'
        Assert-Equal 3 $point.FileCount 'Milestone grouped zip should expose all three save files.'
    }

    Invoke-Test 'restores a complete save from one grouped zip' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-ZipFromText (Join-Path $cfg.backupFolderPath 'zipgroup__2026-06-04_20-00.zip') @{
            'zipgroup.scop' = 'zip-scope'
            'zipgroup.scoc' = 'zip-scoc'
            'zipgroup.dds'  = 'zip-thumb'
        }

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'zipgroup' 'Zip'
        $result = Invoke-RestorePoint -Config $cfg -RestorePoint $point -Confirmed

        Assert-True $result.Success 'Grouped zip restore did not report success.'
        Assert-Equal 'zip-scope' ((Get-Content -LiteralPath (Join-Path $cfg.saveFolderPath 'zipgroup.scop') -Raw).Trim()) 'Grouped zip .scop was not restored.'
        Assert-Equal 'zip-scoc' ((Get-Content -LiteralPath (Join-Path $cfg.saveFolderPath 'zipgroup.scoc') -Raw).Trim()) 'Grouped zip .scoc was not restored.'
        Assert-Equal 'zip-thumb' ((Get-Content -LiteralPath (Join-Path $cfg.saveFolderPath 'zipgroup.dds') -Raw).Trim()) 'Grouped zip .dds was not restored.'
    }

    Invoke-Test 'blocks path traversal inside a grouped zip before copying anything' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-ZipFromText (Join-Path $cfg.backupFolderPath 'evilgroup__2026-06-04_21-00.zip') @{
            '..\evil.scop'  = 'evil-scope'
            'evilgroup.scoc' = 'evil-scoc'
        }

        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'evilgroup' 'Zip'
        $message = $null
        try { Invoke-RestorePoint -Config $cfg -RestorePoint $point -Confirmed | Out-Null } catch { $message = $_.Exception.Message }

        Assert-True ($message -like '*unsafe zip entry*') 'Grouped zip traversal was not rejected.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.saveFolderPath -File).Count 'Unsafe grouped zip copied files.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'evil.scop'))) 'Grouped zip traversal wrote outside the save folder.'
    }

    Invoke-Test 'restore requires explicit confirmation' {
        $root = New-TestRoot
        $cfg = Initialize-TestConfig -Root $root
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_22-00-00.scop' 'backup-scope' | Out-Null
        New-FakeFile $cfg.backupFolderPath 'quicksave__2026-06-04_22-00-00.scoc' 'backup-scoc' | Out-Null
        $point = Get-PointBySave @(Get-RestorePoints -Config $cfg) 'quicksave' 'Rolling'

        $message = $null
        try { Invoke-RestorePoint -Config $cfg -RestorePoint $point | Out-Null } catch { $message = $_.Exception.Message }

        Assert-True ($message -like '*explicit confirmation*') 'Restore did not require explicit confirmation.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $cfg.saveFolderPath -File).Count 'Unconfirmed restore copied files.'
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
    Write-Host ("{0} restore test(s) failed; {1} passed." -f $script:Failed, $script:Passed) -ForegroundColor Red
    exit 1
}

Write-Host ("All {0} restore tests passed." -f $script:Passed) -ForegroundColor Green
