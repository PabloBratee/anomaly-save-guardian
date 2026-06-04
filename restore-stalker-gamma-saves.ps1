<#
.SYNOPSIS
    Safe restore helpers for Anomaly Save Guardian.
.DESCRIPTION
    Discovers restore points created by backup-stalker-gamma-saves.ps1 and
    restores a selected complete .scop + .scoc pair after first creating a
    pre-restore safety backup of any live files that would be overwritten.

    Intended to be dot-sourced by the GUI and tests. It uses only built-in
    PowerShell / .NET APIs and remains compatible with Windows PowerShell 5.1.
#>
[CmdletBinding()]
param([switch]$AsLibrary)

$ErrorActionPreference = 'Stop'

function Write-RestoreLog {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string] $Level = 'INFO'
    )
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log $Message $Level
    }
    else {
        Write-Host ("[{0}] {1}" -f $Level, $Message)
    }
}

function Get-FullRestorePath {
    param([Parameter(Mandatory)] [string] $Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathInsideFolder {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Folder
    )
    $fullPath = Get-FullRestorePath $Path
    $fullFolder = (Get-FullRestorePath $Folder).TrimEnd('\', '/')
    return ($fullPath -ieq $fullFolder -or $fullPath.StartsWith($fullFolder + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase))
}

function Assert-RestoreConfig {
    param([Parameter(Mandatory)] $Config)
    foreach ($name in @('saveFolderPath', 'backupFolderPath', 'milestoneFolderPath')) {
        if (-not $Config.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$Config.$name)) {
            throw "Restore needs a configured $name."
        }
    }
    if (-not (Test-Path -LiteralPath $Config.saveFolderPath -PathType Container)) {
        throw "Save folder was not found: $($Config.saveFolderPath)"
    }
    if (-not (Test-Path -LiteralPath $Config.backupFolderPath -PathType Container)) {
        throw "Backup folder was not found: $($Config.backupFolderPath)"
    }
}

function Get-RestoreFileInfoFromName {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo] $File,
        [Parameter(Mandatory)] [string] $Type
    )

    $name = $File.Name
    $isZip = $false
    if ($name.ToLowerInvariant().EndsWith('.zip')) {
        $isZip = $true
        $name = [System.IO.Path]::GetFileNameWithoutExtension($name)
    }

    $match = [regex]::Match($name, '^(?<save>.+)__(?<timestamp>\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})(?:__(?<collision>\d{3,4}))?(?<ext>\.[^.\\/:]+)$')
    if (-not $match.Success) { return $null }

    $ext = $match.Groups['ext'].Value.ToLowerInvariant()
    if (@('.scop', '.scoc', '.dds') -notcontains $ext) { return $null }

    $saveName = $match.Groups['save'].Value
    if (-not (Test-RestoreSaveName $saveName)) { return $null }

    return [PSCustomObject]@{
        SaveName        = $saveName
        Timestamp       = $match.Groups['timestamp'].Value
        CollisionSuffix = $match.Groups['collision'].Value
        Extension       = $ext
        SourcePath      = $File.FullName
        SourceName      = $File.Name
        Size            = [int64]$File.Length
        Type            = $(if ($isZip) { 'Zip' } else { $Type })
        IsZip           = $isZip
        DestinationName = "$saveName$ext"
    }
}

function Test-RestoreSaveName {
    param([string] $SaveName)
    if ([string]::IsNullOrWhiteSpace($SaveName)) { return $false }
    if ($SaveName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $false }
    if ($SaveName -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
    return $true
}

function Add-RestoreFileToGroups {
    param(
        [Parameter(Mandatory)] [hashtable] $Groups,
        [Parameter(Mandatory)] $Info
    )
    $key = "{0}|{1}|{2}" -f $Info.Type, $Info.SaveName, $Info.Timestamp
    if (-not $Groups.ContainsKey($key)) {
        $Groups[$key] = [PSCustomObject]@{
            Type      = $Info.Type
            SaveName  = $Info.SaveName
            Timestamp = $Info.Timestamp
            Files     = @()
        }
    }
    $Groups[$key].Files = @($Groups[$key].Files + $Info)
}

function New-RestorePointFromGroup {
    param([Parameter(Mandatory)] $Group)

    $files = @($Group.Files | Sort-Object Extension)
    $exts = @($files | ForEach-Object { $_.Extension } | Select-Object -Unique)
    $missing = @()
    foreach ($required in @('.scop', '.scoc')) {
        if ($exts -notcontains $required) { $missing += $required }
    }
    $isComplete = ($missing.Count -eq 0)
    $status = if ($isComplete) { 'Complete' } elseif ($missing.Count -gt 0) { 'Missing pair' } else { 'Incomplete' }
    $id = "{0}|{1}|{2}" -f $Group.Type, $Group.SaveName, $Group.Timestamp

    return [PSCustomObject]@{
        Id                = $id
        SaveName          = $Group.SaveName
        Timestamp         = $Group.Timestamp
        Type              = $Group.Type
        Status            = $status
        IsComplete        = $isComplete
        MissingExtensions = $missing
        FileCount         = $files.Count
        Files             = $files
    }
}

function Get-RestorePoints {
    param([Parameter(Mandatory)] $Config)

    Assert-RestoreConfig -Config $Config
    $groups = @{}
    $locations = @(
        [PSCustomObject]@{ Path = $Config.backupFolderPath; Type = 'Rolling' },
        [PSCustomObject]@{ Path = $Config.milestoneFolderPath; Type = 'Milestone' }
    )

    foreach ($loc in $locations) {
        if (-not (Test-Path -LiteralPath $loc.Path -PathType Container)) { continue }
        $files = @(Get-ChildItem -LiteralPath $loc.Path -File -ErrorAction Stop)
        foreach ($file in $files) {
            $info = Get-RestoreFileInfoFromName -File $file -Type $loc.Type
            if ($null -eq $info) { continue }
            Add-RestoreFileToGroups -Groups $groups -Info $info
        }
    }

    $points = foreach ($key in $groups.Keys) {
        New-RestorePointFromGroup -Group $groups[$key]
    }
    return @($points | Sort-Object Timestamp, SaveName -Descending)
}

function Test-RestorePointSources {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $RestorePoint
    )
    $allowedRoots = @($Config.backupFolderPath, $Config.milestoneFolderPath)
    foreach ($file in @($RestorePoint.Files)) {
        $inside = $false
        foreach ($root in $allowedRoots) {
            if ($root -and (Test-PathInsideFolder -Path $file.SourcePath -Folder $root)) {
                $inside = $true
                break
            }
        }
        if (-not $inside) {
            throw "Restore source is outside the configured backup folders: $($file.SourcePath)"
        }
        if (-not (Test-Path -LiteralPath $file.SourcePath -PathType Leaf)) {
            throw "Restore source is missing: $($file.SourcePath)"
        }
        if (@('.scop', '.scoc', '.dds') -notcontains ([string]$file.Extension).ToLowerInvariant()) {
            throw "Restore source has an unexpected file type: $($file.SourcePath)"
        }
        if (-not (Test-RestoreSaveName ([System.IO.Path]::GetFileNameWithoutExtension($file.DestinationName)))) {
            throw "Restore destination name is not safe: $($file.DestinationName)"
        }
    }
}

function Test-RestorePointReady {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $RestorePoint
    )
    Assert-RestoreConfig -Config $Config
    if (-not $RestorePoint.IsComplete) {
        throw "Selected backup is incomplete. Restore needs a complete .scop + .scoc pair."
    }
    Test-RestorePointSources -Config $Config -RestorePoint $RestorePoint
}

function Get-RestoreDestinationPath {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $DestinationName
    )
    $leaf = Split-Path -Leaf $DestinationName
    if ($leaf -ne $DestinationName) { throw "Restore destination must be a file name only: $DestinationName" }
    if ($leaf.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Restore destination name is not safe: $leaf" }
    $dest = Join-Path $Config.saveFolderPath $leaf
    if (-not (Test-PathInsideFolder -Path $dest -Folder $Config.saveFolderPath)) {
        throw "Restore destination is outside the configured save folder: $dest"
    }
    return $dest
}

function New-PreRestoreSafetyBackup {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $RestorePoint
    )
    $safeName = $RestorePoint.SaveName -replace '[^\w.\- ]', '_'
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'save' }
    $root = Join-Path $Config.backupFolderPath 'PreRestoreSafetyBackups'
    $folderName = "{0}_restore_{1}" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'), $safeName
    $folder = Join-Path $root $folderName

    try {
        if (Test-Path -LiteralPath $root -PathType Leaf) {
            throw "Safety backup location is blocked by a file: $root"
        }
        if (Test-Path -LiteralPath $folder) {
            for ($i = 2; $i -le 9999; $i++) {
                $candidate = Join-Path $root ("{0}__{1:D3}" -f $folderName, $i)
                if (-not (Test-Path -LiteralPath $candidate)) {
                    $folder = $candidate
                    break
                }
            }
            if (Test-Path -LiteralPath $folder) {
                throw "Could not create a unique pre-restore safety backup folder: $folder"
            }
        }
        New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            throw "Safety backup folder was not created: $folder"
        }
        Write-RestoreLog "Created pre-restore safety backup folder '$folder'." 'INFO'
    }
    catch {
        throw "Could not create pre-restore safety backup: $($_.Exception.Message)"
    }

    $lines = @(
        "Restore safety backup",
        "Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Save: $($RestorePoint.SaveName)",
        "Restore point: $($RestorePoint.Type) $($RestorePoint.Timestamp)",
        "Live files copied before restore:"
    )
    $copied = 0
    foreach ($file in @($RestorePoint.Files)) {
        $dest = Get-RestoreDestinationPath -Config $Config -DestinationName $file.DestinationName
        if (Test-Path -LiteralPath $dest -PathType Leaf) {
            $safeDest = Join-Path $folder (Split-Path -Leaf $dest)
            try {
                Copy-Item -LiteralPath $dest -Destination $safeDest -Force -ErrorAction Stop
                $copied++
                $lines += "COPIED $dest -> $safeDest"
                Write-RestoreLog "Safety-backed up live file '$dest'." 'INFO'
            }
            catch {
                throw "Could not create pre-restore safety backup: $($_.Exception.Message)"
            }
        }
        else {
            $lines += "NOT PRESENT $dest"
        }
    }

    if ($copied -eq 0) {
        $lines += 'No existing live files were present to copy.'
    }
    $manifest = Join-Path $folder 'restore-manifest.txt'
    try {
        Set-Content -LiteralPath $manifest -Value $lines -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        throw "Could not write pre-restore safety backup manifest: $($_.Exception.Message)"
    }
    return $folder
}

function Expand-ZipRestoreSources {
    param(
        [Parameter(Mandatory)] $RestorePoint
    )
    # FileSystem gives ZipFile; the base assembly gives ZipArchive/ZipArchiveEntry
    # (not auto-loaded on Windows PowerShell 5.1).
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sgb-restore-zip-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $expanded = @()
    try {
        foreach ($file in @($RestorePoint.Files)) {
            if (-not $file.IsZip) {
                $expanded += $file
                continue
            }
            $zip = [System.IO.Compression.ZipFile]::OpenRead($file.SourcePath)
            try {
                $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
                if ($entries.Count -ne 1) {
                    throw "Zip backup must contain exactly one save file: $($file.SourcePath)"
                }
                $entry = $entries[0]
                $entryLeaf = Split-Path -Leaf $entry.FullName
                if ($entry.FullName -ne $entryLeaf -or $entry.FullName -match '(^|[\\/])\.\.([\\/]|$)') {
                    throw "Blocked unsafe zip entry '$($entry.FullName)' in '$($file.SourcePath)'."
                }
                if ($entryLeaf -ne $file.DestinationName) {
                    throw "Zip backup contains '$entryLeaf' but restore expected '$($file.DestinationName)'."
                }
                if ([System.IO.Path]::GetExtension($entryLeaf).ToLowerInvariant() -ne $file.Extension) {
                    throw "Zip backup contains an unexpected file type: $entryLeaf"
                }

                $dest = Join-Path $tempRoot $entryLeaf
                if (-not (Test-PathInsideFolder -Path $dest -Folder $tempRoot)) {
                    throw "Blocked unsafe zip entry '$($entry.FullName)' in '$($file.SourcePath)'."
                }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
                $expanded += [PSCustomObject]@{
                    Extension       = $file.Extension
                    SourcePath      = $dest
                    OriginalSource  = $file.SourcePath
                    DestinationName = $file.DestinationName
                    Size            = (Get-Item -LiteralPath $dest).Length
                    IsZip           = $false
                    TempRoot        = $tempRoot
                }
            }
            finally {
                $zip.Dispose()
            }
        }
        return [PSCustomObject]@{
            Files    = $expanded
            TempRoot = $tempRoot
        }
    }
    catch {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Invoke-RestorePoint {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $RestorePoint,
        [switch] $Confirmed
    )

    if (-not $Confirmed) {
        throw "Restore requires explicit confirmation."
    }

    Test-RestorePointReady -Config $Config -RestorePoint $RestorePoint
    $zipStage = $null
    $sourceFiles = @($RestorePoint.Files)
    $previousProtectedVar = Get-Variable -Name RetentionProtectedPaths -Scope Script -ErrorAction SilentlyContinue
    $protected = @{}
    foreach ($file in @($RestorePoint.Files)) {
        $protected[(Get-FullRestorePath $file.SourcePath).ToLowerInvariant()] = $true
    }
    $script:RetentionProtectedPaths = $protected

    try {
        if (@($sourceFiles | Where-Object { $_.IsZip }).Count -gt 0) {
            $zipStage = Expand-ZipRestoreSources -RestorePoint $RestorePoint
            $sourceFiles = @($zipStage.Files)
        }

        foreach ($file in $sourceFiles) {
            Get-RestoreDestinationPath -Config $Config -DestinationName $file.DestinationName | Out-Null
        }

        $safetyFolder = New-PreRestoreSafetyBackup -Config $Config -RestorePoint $RestorePoint

        $restored = @()
        foreach ($file in $sourceFiles) {
            $dest = Get-RestoreDestinationPath -Config $Config -DestinationName $file.DestinationName
            try {
                Copy-Item -LiteralPath $file.SourcePath -Destination $dest -Force -ErrorAction Stop
                $sourceLen = (Get-Item -LiteralPath $file.SourcePath -ErrorAction Stop).Length
                $destItem = Get-Item -LiteralPath $dest -ErrorAction Stop
                if ($destItem.Length -ne $sourceLen) {
                    throw "Restored file size mismatch for '$dest'."
                }
                $restored += $dest
                Write-RestoreLog "Restored '$($file.DestinationName)' to the live save folder." 'SUCCESS'
            }
            catch {
                throw "Restore partially failed after copying started. Safety backup kept at '$safetyFolder'. Last error: $($_.Exception.Message)"
            }
        }

        return [PSCustomObject]@{
            Success            = $true
            SaveName           = $RestorePoint.SaveName
            Type               = $RestorePoint.Type
            Timestamp          = $RestorePoint.Timestamp
            RestoredFiles      = $restored
            SafetyBackupFolder = $safetyFolder
        }
    }
    finally {
        if ($zipStage -and $zipStage.TempRoot -and (Test-Path -LiteralPath $zipStage.TempRoot)) {
            Remove-Item -LiteralPath $zipStage.TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($previousProtectedVar) {
            $script:RetentionProtectedPaths = $previousProtectedVar.Value
        }
        else {
            Remove-Variable -Name RetentionProtectedPaths -Scope Script -ErrorAction SilentlyContinue
        }
    }
}

function Get-RunningGameProcessNames {
    $known = @(
        'AnomalyDX11AVX', 'AnomalyDX11', 'AnomalyDX10', 'AnomalyDX9',
        'xrEngine', 'GAMMA', 'Anomaly'
    )
    $running = @()
    try {
        $processes = @(Get-Process -ErrorAction Stop)
        foreach ($proc in $processes) {
            foreach ($name in $known) {
                if ($proc.ProcessName -ieq $name -or $proc.ProcessName -like "*$name*") {
                    $running += $proc.ProcessName
                    break
                }
            }
        }
    }
    catch { }
    return @($running | Sort-Object -Unique)
}

if ($AsLibrary) { return }

Write-Host 'This script is a restore helper library for the GUI and tests.'
