<#
.SYNOPSIS
    Automatic backup tool for STALKER GAMMA save files.

.DESCRIPTION
    Watches your STALKER GAMMA save folder and copies every new or changed save
    file to a backup folder. Uses only built-in PowerShell / .NET features.

    The original save files are NEVER modified, renamed, moved, or deleted.
    They are only ever opened for reading / copying.

    Configuration is read from 'stalker-gamma-backup-config.json' located in the
    SAME folder as this script.

.PARAMETER BackupNow
    Immediately back up all existing save files once, then exit
    (unless -Watch is also supplied).

.PARAMETER Watch
    Continuously watch the save folder and back up files as they change.
    Runs until you close the terminal or press Ctrl+C.

.PARAMETER Milestone
    Take a milestone restore point from the newest complete logical save group.
    Milestones are retained in the milestone folder according to config.

.PARAMETER DryRun
    Show what would happen without copying, zipping, or deleting anything.

.EXAMPLE
    .\backup-stalker-gamma-saves.ps1 -BackupNow
.EXAMPLE
    .\backup-stalker-gamma-saves.ps1 -Watch
.EXAMPLE
    .\backup-stalker-gamma-saves.ps1 -Milestone
.EXAMPLE
    .\backup-stalker-gamma-saves.ps1 -BackupNow -DryRun
.EXAMPLE
    .\backup-stalker-gamma-saves.ps1 -Watch -DryRun
#>

[CmdletBinding()]
param(
    [switch]$BackupNow,
    [switch]$Watch,
    [switch]$Milestone,
    [switch]$DryRun,
    # When set, the script only DEFINES its functions and then returns, so other
    # scripts (e.g. the GUI) can dot-source it as a library without running a mode.
    [switch]$AsLibrary
)

# Stop on errors so try/catch blocks reliably catch them. The long-running watch
# loop wraps risky work in try/catch so a single bad file can never kill it.
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Script-scope state
# ---------------------------------------------------------------------------
$script:AppVersion  = '1.0.0'        # bumped in CHANGELOG.md
$script:Config      = $null          # normalized config object
$script:BackupCache = @{}            # saveName -> group signature of last backup made

# A logical save = one .scop + one .scoc, plus an optional .dds thumbnail, all
# sharing the same base file name. .scop + .scoc are REQUIRED for a complete
# save; .dds is optional. These drive grouping and "complete" checks.
$script:RequiredSaveExtensions = @('.scop', '.scoc')

# Timestamp pattern shared by the filename parsers. Seconds are optional so both
# new minute-precision rolling backups (yyyy-MM-dd_HH-mm) and older / milestone
# second-precision names (yyyy-MM-dd_HH-mm-ss) are recognized.
$script:BackupTimestampPattern = '\d{4}-\d{2}-\d{2}_\d{2}-\d{2}(?:-\d{2})?'

# ===========================================================================
# Logging
# ===========================================================================
function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DRYRUN')]
        [string] $Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line      = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        'DRYRUN'  { Write-Host $line -ForegroundColor Cyan }
        default   { Write-Host $line -ForegroundColor Gray }
    }

    # Optional extra sink (e.g. the GUI registers one to mirror lines into its log).
    if ($script:LogSink) {
        try { & $script:LogSink $line $Level } catch { }
    }

    # Best-effort file logging. Never let a logging failure crash the script
    # (e.g. the backup drive holding the log file may be temporarily offline).
    if ($null -ne $script:Config -and -not [string]::IsNullOrWhiteSpace($script:Config.logFilePath)) {
        try {
            $logDir = Split-Path -Parent $script:Config.logFilePath
            if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            Add-Content -LiteralPath $script:Config.logFilePath -Value $line -Encoding UTF8
        }
        catch {
            Write-Host "[$timestamp] [WARN] Could not write to log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# ===========================================================================
# Config loading + validation
# ===========================================================================
function Get-ScriptDirectory {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Import-BackupConfig {
    param([Parameter(Mandatory)] [string] $ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found next to the script: '$ConfigPath'"
    }

    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    }
    catch {
        throw "Could not read config file '$ConfigPath': $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Config file '$ConfigPath' is empty."
    }

    try {
        $cfg = $raw | ConvertFrom-Json
    }
    catch {
        throw "Config file '$ConfigPath' is not valid JSON: $($_.Exception.Message)"
    }

    # --- Validate required keys exist ---
    $required = @(
        'saveFolderPath', 'backupFolderPath', 'includeExtensions',
        'backupDelaySeconds', 'keepMaxBackupsPerSave', 'enableZipBackup', 'logFilePath'
    )
    $present = @($cfg.PSObject.Properties.Name)
    foreach ($key in $required) {
        if ($present -notcontains $key) {
            throw "Config is missing required key: '$key'"
        }
    }

    # --- Validate values ---
    if ([string]::IsNullOrWhiteSpace($cfg.saveFolderPath)) {
        throw "Config 'saveFolderPath' must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($cfg.backupFolderPath)) {
        throw "Config 'backupFolderPath' must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($cfg.logFilePath)) {
        throw "Config 'logFilePath' must not be empty."
    }
    if (-not ($cfg.includeExtensions) -or @($cfg.includeExtensions).Count -eq 0) {
        throw "Config 'includeExtensions' must be a non-empty array, e.g. ['.sav', '.scop']."
    }

    $delay = 0.0
    if (-not [double]::TryParse([string]$cfg.backupDelaySeconds, [ref]$delay) -or $delay -lt 0) {
        throw "Config 'backupDelaySeconds' must be a number >= 0."
    }

    $keep = 0
    if (-not [int]::TryParse([string]$cfg.keepMaxBackupsPerSave, [ref]$keep) -or $keep -lt 1) {
        throw "Config 'keepMaxBackupsPerSave' must be a whole number >= 1."
    }

    $keepMilestones = 5
    if ($present -contains 'keepMaxMilestones') {
        if (-not [int]::TryParse([string]$cfg.keepMaxMilestones, [ref]$keepMilestones) -or $keepMilestones -lt 1) {
            throw "Config 'keepMaxMilestones' must be a whole number >= 1."
        }
    }

    if ($cfg.enableZipBackup -isnot [bool]) {
        throw "Config 'enableZipBackup' must be true or false."
    }

    # --- Normalize extensions: lowercase, ensure leading dot ---
    $normExt = foreach ($e in $cfg.includeExtensions) {
        $x = ([string]$e).Trim().ToLowerInvariant()
        if ($x -and -not $x.StartsWith('.')) { $x = ".$x" }
        $x
    }
    $normExt = @($normExt | Where-Object { $_ })

    # milestoneFolderPath is optional. If omitted, default to a 'Milestones'
    # subfolder inside the backup folder. Milestone retention is scoped only to
    # this folder.
    $milestone = $null
    if (($present -contains 'milestoneFolderPath') -and -not [string]::IsNullOrWhiteSpace($cfg.milestoneFolderPath)) {
        $milestone = [string]$cfg.milestoneFolderPath
    }
    else {
        $milestone = Join-Path ([string]$cfg.backupFolderPath) 'Milestones'
    }

    $looksLikeOldUntouchedDefault =
        ($keep -eq 200 -or $keep -eq 10) -and
        ([string]$cfg.saveFolderPath -ieq 'C:\Anomaly\appdata\savedgames') -and
        ([string]$cfg.backupFolderPath -ieq 'D:\STALKER GAMMA Backups') -and
        ([string]$milestone -ieq 'D:\STALKER GAMMA Backups\Milestones') -and
        ((@($normExt) -join '|') -eq '.sav|.scop|.scoc|.dds') -and
        $delay -eq 3 -and
        ([bool]$cfg.enableZipBackup) -eq $false -and
        ([string]$cfg.logFilePath -ieq 'D:\STALKER GAMMA Backups\backup-log.txt')
    if ($looksLikeOldUntouchedDefault) {
        $keep = 5
        if (($present -notcontains 'keepMaxMilestones') -or $keepMilestones -eq 10 -or $keepMilestones -eq 200) {
            $keepMilestones = 5
        }
    }

    # Return a clean, typed object.
    return [PSCustomObject]@{
        saveFolderPath        = [string]$cfg.saveFolderPath
        backupFolderPath      = [string]$cfg.backupFolderPath
        milestoneFolderPath   = $milestone
        includeExtensions     = $normExt
        backupDelaySeconds    = $delay
        keepMaxBackupsPerSave = $keep
        keepMaxMilestones     = $keepMilestones
        enableZipBackup       = [bool]$cfg.enableZipBackup
        logFilePath           = [string]$cfg.logFilePath
    }
}

# Write a config object back to disk as nicely-ordered JSON. Used by the
# Settings dialog in the GUI so folders can be changed without editing JSON.
function Save-BackupConfig {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Path
    )
    $keepMilestones = 5
    if ($Config.PSObject.Properties.Name -contains 'keepMaxMilestones') {
        $keepMilestones = [int]$Config.keepMaxMilestones
    }
    $ordered = [ordered]@{
        saveFolderPath        = [string]$Config.saveFolderPath
        backupFolderPath      = [string]$Config.backupFolderPath
        milestoneFolderPath   = [string]$Config.milestoneFolderPath
        includeExtensions     = @($Config.includeExtensions)
        backupDelaySeconds    = $Config.backupDelaySeconds
        keepMaxBackupsPerSave = [int]$Config.keepMaxBackupsPerSave
        keepMaxMilestones     = $keepMilestones
        enableZipBackup       = [bool]$Config.enableZipBackup
        logFilePath           = [string]$Config.logFilePath
    }
    # ConvertTo-Json renders a single-element array as a scalar; the loader copes
    # with both, but we keep depth explicit for clarity.
    ($ordered | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Path -Encoding UTF8
}

# First-run helper: if the personal config is missing, seed it from the bundled
# example template so the tool (and a freshly cloned repo) works out of the box.
function Initialize-ConfigIfMissing {
    param(
        [Parameter(Mandatory)] [string] $ConfigPath,
        [string] $ExamplePath
    )
    if (Test-Path -LiteralPath $ConfigPath) { return }
    if ($ExamplePath -and (Test-Path -LiteralPath $ExamplePath)) {
        Copy-Item -LiteralPath $ExamplePath -Destination $ConfigPath -Force
        Write-Log "No config found - created '$ConfigPath' from the example. Set your folders in Settings (or edit the file)." 'WARN'
    }
}

# ===========================================================================
# Helpers
# ===========================================================================

# Ensure a directory exists, creating it if needed. Logs on creation.
function Confirm-Directory {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Log "Created folder: '$Path'"
    }
}

# Is the backup target drive currently available? (e.g. G: connected)
function Test-BackupTargetAvailable {
    try {
        $qualifier = Split-Path -Qualifier $script:Config.backupFolderPath  # e.g. "G:"
        if (-not $qualifier) { return $true }  # UNC / relative; let later steps decide
        return (Test-Path -LiteralPath "$qualifier\")
    }
    catch {
        return $false
    }
}

# Verify a file is fully written: size stable across a short interval AND not
# locked by another process (opened for read with no sharing). Returns $true/$false.
function Test-FileReady {
    param([Parameter(Mandatory)] [string] $Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $sizeA = (Get-Item -LiteralPath $Path).Length
        Start-Sleep -Milliseconds 500
        $sizeB = (Get-Item -LiteralPath $Path).Length
        if ($sizeA -ne $sizeB) { return $false }  # still growing -> being written

        # Try to open exclusively for read. If the game still holds the file open
        # for writing, this throws and we treat the file as not ready.
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                                          [System.IO.FileAccess]::Read,
                                          [System.IO.FileShare]::None)
        $stream.Close()
        $stream.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

# Copy a save file to the destination, retrying a few times if briefly locked.
# READ-ONLY with respect to the source: it is only ever read/copied.
function Copy-SaveFile {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination
    )
    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return $true
        }
        catch [System.UnauthorizedAccessException] {
            Write-Log "Permission denied copying '$Source': $($_.Exception.Message)" 'ERROR'
            return $false
        }
        catch {
            Write-Log "Copy attempt $attempt/$maxAttempts failed for '$Source': $($_.Exception.Message)" 'WARN'
            Start-Sleep -Seconds 1
        }
    }
    return $false
}

# Create a timestamped .zip containing every file of ONE logical save group
# (.scop + .scoc + optional .dds). One zip == one save. Sources are read-only and
# stored under their original live file names so restore can extract them back.
function New-ZipBackupGroup {
    param(
        [Parameter(Mandatory)] [string[]] $Sources,
        [Parameter(Mandatory)] [string] $DestinationZip
    )
    try {
        # FileSystem gives ZipFile/ZipFileExtensions; the base assembly gives
        # ZipArchive/ZipArchiveMode (not auto-loaded on Windows PowerShell 5.1).
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $DestinationZip) {
            Remove-Item -LiteralPath $DestinationZip -Force
        }
        $zip = [System.IO.Compression.ZipFile]::Open($DestinationZip, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($source in $Sources) {
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zip, $source, [System.IO.Path]::GetFileName($source)) | Out-Null
            }
        }
        finally {
            $zip.Dispose()
        }
        return $true
    }
    catch [System.UnauthorizedAccessException] {
        Write-Log "Permission denied creating zip for '$DestinationZip': $($_.Exception.Message)" 'ERROR'
        return $false
    }
    catch {
        Write-Log "Zip backup failed for '$DestinationZip': $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# Discover the logical save groups in a folder. Files are grouped by base name
# (the file name without its extension) so '<name>.scop', '<name>.scoc' and
# '<name>.dds' are treated as ONE save named '<name>'. Only configured
# includeExtensions participate. Returns objects: SaveName, Files, IsComplete.
function Get-LiveSaveGroups {
    param([Parameter(Mandatory)] [string] $Folder)

    $groups = [ordered]@{}
    $files = @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction Stop |
               Where-Object { $script:Config.includeExtensions -contains $_.Extension.ToLowerInvariant() })
    foreach ($file in $files) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $key = $base.ToLowerInvariant()
        if (-not $groups.Contains($key)) {
            $groups[$key] = [PSCustomObject]@{ SaveName = $base; Files = @() }
        }
        $groups[$key].Files = @($groups[$key].Files + $file)
    }

    foreach ($key in $groups.Keys) {
        $group = $groups[$key]
        Add-Member -InputObject $group -NotePropertyName IsComplete -NotePropertyValue (Test-SaveGroupComplete -Files $group.Files) -Force
        $group
    }
}

# A group is complete when every REQUIRED extension that the user actually backs
# up is present. If neither .scop nor .scoc is in includeExtensions (a custom
# setup), there is no pair to require and any group counts as complete.
function Test-SaveGroupComplete {
    param([Parameter(Mandatory)] [System.IO.FileInfo[]] $Files)
    $exts = @($Files | ForEach-Object { $_.Extension.ToLowerInvariant() })
    $requiredConfigured = @($script:RequiredSaveExtensions | Where-Object { $script:Config.includeExtensions -contains $_ })
    if ($requiredConfigured.Count -eq 0) { return $true }
    foreach ($required in $requiredConfigured) {
        if ($exts -notcontains $required) { return $false }
    }
    return $true
}

function Get-SaveGroupNewestWriteUtc {
    param([Parameter(Mandatory)] [System.IO.FileInfo[]] $Files)
    if (@($Files).Count -eq 0) { return [datetime]::MinValue }
    $newest = @($Files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($newest.Count -eq 0) { return [datetime]::MinValue }
    return $newest[0].LastWriteTimeUtc
}

function Get-NewestCompleteLiveSaveGroup {
    param([Parameter(Mandatory)] [string] $Folder)

    $groups = @(Get-LiveSaveGroups -Folder $Folder)
    foreach ($group in $groups) {
        Add-Member -InputObject $group -NotePropertyName NewestWriteUtc -NotePropertyValue (Get-SaveGroupNewestWriteUtc -Files @($group.Files)) -Force
    }

    $ordered = @($groups | Sort-Object @{ Expression = 'NewestWriteUtc'; Descending = $true }, @{ Expression = 'SaveName'; Descending = $true })
    $complete = @($ordered | Where-Object { $_.IsComplete })

    return [PSCustomObject]@{
        Groups       = $ordered
        Newest       = if ($ordered.Count -gt 0) { $ordered[0] } else { $null }
        Complete     = if ($complete.Count -gt 0) { $complete[0] } else { $null }
        CompleteList = $complete
    }
}

# A stable fingerprint of a save group (sorted name|ticks|length per file) used to
# skip re-backing up a group that has not changed since the last successful backup.
function Get-SaveGroupSignature {
    param([Parameter(Mandatory)] [System.IO.FileInfo[]] $Files)
    $parts = @($Files | Sort-Object Name | ForEach-Object {
        "{0}|{1}|{2}" -f $_.Name, $_.LastWriteTimeUtc.Ticks, $_.Length
    })
    return ($parts -join '||')
}

# Compute a collision-safe suffix so a whole group keeps one shared timestamp
# token. Used by milestones (which keep permanent snapshot names). Rolling
# backups overwrite/replace by save name instead, so they pass no suffix.
function Get-UniqueGroupSuffix {
    param(
        [Parameter(Mandatory)] [string] $DestFolder,
        [Parameter(Mandatory)] [string] $SaveName,
        [Parameter(Mandatory)] [string] $Timestamp,
        [Parameter(Mandatory)] [string[]] $Extensions,
        [switch] $Zip
    )
    $exists = {
        param($suffix)
        if ($Zip) {
            return (Test-Path -LiteralPath (Join-Path $DestFolder ("{0}__{1}{2}.zip" -f $SaveName, $Timestamp, $suffix)))
        }
        foreach ($ext in $Extensions) {
            if (Test-Path -LiteralPath (Join-Path $DestFolder ("{0}__{1}{2}{3}" -f $SaveName, $Timestamp, $suffix, $ext))) { return $true }
        }
        return $false
    }
    if (-not (& $exists '')) { return '' }
    for ($i = 2; $i -le 9999; $i++) {
        $suffix = "__{0:D3}" -f $i
        if (-not (& $exists $suffix)) { return $suffix }
    }
    throw "Could not create a unique backup name for '$SaveName' in '$DestFolder'."
}

# Write ONE logical save group to a destination folder under a shared timestamp.
# Zip mode -> a single '<save>__<timestamp>.zip' holding every file.
# Plain mode -> '<save>__<timestamp><ext>' per file (shared timestamp keeps the
# group together for restore). Returns the full paths written, or $null on failure.
function New-SaveGroupBackup {
    param(
        [Parameter(Mandatory)] [string] $SaveName,
        [Parameter(Mandatory)] [System.IO.FileInfo[]] $Files,
        [Parameter(Mandatory)] [string] $DestFolder,
        [Parameter(Mandatory)] [string] $Timestamp,
        [switch] $UniqueCollision
    )
    $sorted = @($Files | Sort-Object Name)
    $exts = @($sorted | ForEach-Object { $_.Extension.ToLowerInvariant() })
    $suffix = ''
    if ($UniqueCollision) {
        $suffix = Get-UniqueGroupSuffix -DestFolder $DestFolder -SaveName $SaveName -Timestamp $Timestamp -Extensions $exts -Zip:([bool]$script:Config.enableZipBackup)
    }

    if ($script:Config.enableZipBackup) {
        $zipPath = Join-Path $DestFolder ("{0}__{1}{2}.zip" -f $SaveName, $Timestamp, $suffix)
        if (New-ZipBackupGroup -Sources @($sorted | ForEach-Object { $_.FullName }) -DestinationZip $zipPath) {
            return @($zipPath)
        }
        return $null
    }

    $written = @()
    foreach ($file in $sorted) {
        $ext = $file.Extension.ToLowerInvariant()
        $dest = Join-Path $DestFolder ("{0}__{1}{2}{3}" -f $SaveName, $Timestamp, $suffix, $ext)
        if (Copy-SaveFile -Source $file.FullName -Destination $dest) {
            $written += $dest
        }
        else {
            # Roll back any partial group write so we never leave a half-saved set.
            foreach ($done in $written) {
                Remove-Item -LiteralPath $done -Force -ErrorAction SilentlyContinue
            }
            return $null
        }
    }
    return $written
}

# Return the requested backup path, or a suffixed sibling if that exact timestamp
# already exists. Used for compatibility tests and collision-safe snapshot names.
function Get-UniqueBackupPath {
    param([Parameter(Mandatory)] [string] $DestinationPath)

    if (-not (Test-Path -LiteralPath $DestinationPath)) { return $DestinationPath }

    $dir = Split-Path -Parent $DestinationPath
    $leaf = Split-Path -Leaf $DestinationPath
    $ext = [System.IO.Path]::GetExtension($leaf)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)

    # Zip backups are named "save__timestamp.ext.zip"; keep the collision suffix
    # before the save extension so retention still matches "save__*.ext.zip".
    if ($ext -ieq '.zip') {
        $innerExt = [System.IO.Path]::GetExtension($stem)
        if ($innerExt) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($stem)
            $ext = "$innerExt.zip"
        }
    }

    for ($i = 2; $i -le 9999; $i++) {
        $candidate = Join-Path $dir ("{0}__{1:D3}{2}" -f $stem, $i, $ext)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }

    throw "Could not create a unique backup name for '$DestinationPath'."
}

function Get-FullBackupPath {
    param([Parameter(Mandatory)] [string] $Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathInsideBackupFolder {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Folder
    )
    $fullPath = Get-FullBackupPath $Path
    $fullFolder = (Get-FullBackupPath $Folder).TrimEnd('\', '/')
    return ($fullPath -ieq $fullFolder -or $fullPath.StartsWith($fullFolder + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase))
}

function Get-RollingBackupFileInfoFromName {
    param([Parameter(Mandatory)] [System.IO.FileInfo] $File)

    $name = $File.Name
    $isZip = $false
    $ext = $null

    if ($name.ToLowerInvariant().EndsWith('.zip')) {
        $isZip = $true
        $core = [System.IO.Path]::GetFileNameWithoutExtension($name)   # strip .zip
        # Legacy zips were '<save>__<ts>.<ext>.zip'; new grouped zips are
        # '<save>__<ts>.zip' (no inner save extension). Detect which we have.
        $inner = [System.IO.Path]::GetExtension($core).ToLowerInvariant()
        if ($inner -and ($script:Config.includeExtensions -contains $inner)) {
            $ext = $inner
            $core = [System.IO.Path]::GetFileNameWithoutExtension($core)
        }
        else {
            $ext = '.zip'   # grouped zip: the whole save is in one archive
        }
    }
    else {
        $ext = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
        if ($script:Config.includeExtensions -notcontains $ext) { return $null }
        $core = [System.IO.Path]::GetFileNameWithoutExtension($name)
    }

    $match = [regex]::Match($core, ('^(?<save>.+)__(?<timestamp>{0})(?:__(?<collision>\d{{3,4}}))?$' -f $script:BackupTimestampPattern))
    if (-not $match.Success) { return $null }

    $saveName = $match.Groups['save'].Value
    if ([string]::IsNullOrWhiteSpace($saveName)) { return $null }
    if ($saveName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $null }

    return [PSCustomObject]@{
        SaveName        = $saveName
        Timestamp       = $match.Groups['timestamp'].Value
        CollisionSuffix = $match.Groups['collision'].Value
        Extension       = $ext
        SourcePath      = $File.FullName
        SourceName      = $File.Name
        IsZip           = $isZip
    }
}

function Get-RollingBackupRestorePoints {
    param([Parameter(Mandatory)] [string] $Folder)

    $groups = @{}
    $files = @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction Stop)
    foreach ($file in $files) {
        if (-not (Test-PathInsideBackupFolder -Path $file.FullName -Folder $Folder)) { continue }
        $info = Get-RollingBackupFileInfoFromName -File $file
        if ($null -eq $info) { continue }

        $type = if ($info.IsZip) { 'Zip' } else { 'Rolling' }
        $key = "{0}|{1}|{2}|{3}" -f $type, $info.SaveName, $info.Timestamp, $info.CollisionSuffix
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [PSCustomObject]@{
                Type            = $type
                SaveName        = $info.SaveName
                Timestamp       = $info.Timestamp
                CollisionSuffix = $info.CollisionSuffix
                Files           = @()
            }
        }
        $groups[$key].Files = @($groups[$key].Files + $info)
    }

    $points = foreach ($key in $groups.Keys) {
        $group = $groups[$key]
        [PSCustomObject]@{
            Type            = $group.Type
            SaveName        = $group.SaveName
            Timestamp       = $group.Timestamp
            CollisionSuffix = $group.CollisionSuffix
            Files           = @($group.Files | Sort-Object SourceName)
        }
    }

    return @($points | Sort-Object @{ Expression = 'Timestamp'; Descending = $true }, @{ Expression = 'CollisionSuffix'; Descending = $true }, @{ Expression = 'SaveName'; Descending = $true }, @{ Expression = 'Type'; Descending = $true })
}

function Test-RetentionFileProtected {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Get-Variable -Name RetentionProtectedPaths -Scope Script -ErrorAction SilentlyContinue)) {
        return $false
    }
    if ($null -eq $script:RetentionProtectedPaths) { return $false }

    $fullPath = Get-FullBackupPath $Path
    if ($script:RetentionProtectedPaths -is [hashtable]) {
        return $script:RetentionProtectedPaths.ContainsKey($fullPath.ToLowerInvariant())
    }
    return @($script:RetentionProtectedPaths) -contains $fullPath
}

# Retention: keep only the newest N logical saves in the top level of the backup
# folder and delete older groups as a unit. Conservative +
# scoped to the configured rolling backup folder only. NEVER touches the save
# folder, milestone folder, pre-restore safety folders, logs or config.
function Invoke-Retention {
    param(
        [Parameter(Mandatory)] [string] $Base,
        [Parameter(Mandatory)] [string] $Ext
    )
    try {
        $keep   = [int]$script:Config.keepMaxBackupsPerSave
        $folder = $script:Config.backupFolderPath
        if ($keep -lt 1) { return }
        if (-not (Test-Path -LiteralPath $folder)) { return }

        # Sort by the embedded filename timestamp, not LastWriteTime: Copy-Item
        # preserves the source file timestamp, so filesystem times are not a
        # reliable backup age signal.
        $restorePoints = @(Get-RollingBackupRestorePoints -Folder $folder)
        if ($restorePoints.Count -le $keep) { return }

        $toDelete = @($restorePoints | Select-Object -Skip $keep)
        foreach ($point in $toDelete) {
            foreach ($file in @($point.Files)) {
                if (-not (Test-PathInsideBackupFolder -Path $file.SourcePath -Folder $folder)) { continue }
                if (Test-RetentionFileProtected -Path $file.SourcePath) {
                    Write-Log "Skipped retention delete for active restore source '$($file.SourcePath)'" 'WARN'
                    continue
                }

                if ($DryRun) {
                    Write-Log "[DRY-RUN] Would delete old backup '$($file.SourcePath)'" 'DRYRUN'
                    continue
                }
                try {
                    Remove-Item -LiteralPath $file.SourcePath -Force
                    Write-Log "Deleted old backup '$($file.SourcePath)'"
                }
                catch {
                    Write-Log "Failed to delete old backup '$($file.SourcePath)': $($_.Exception.Message)" 'WARN'
                }
            }
        }
    }
    catch {
        Write-Log "Retention error: $($_.Exception.Message)" 'WARN'
    }
}

# Normal rolling backups keep only the NEWEST backup for each logical save name.
# After a fresh rolling backup, remove every other top-level rolling file with the
# same save name so the same quicksave/autosave/sleep/manual save never piles up
# endless timestamped copies. Strictly scoped to the configured rolling backup
# folder's top level: it never touches the save folder, the Milestones folder, the
# PreRestoreSafetyBackups subfolder, or anything outside the backup folder.
function Invoke-RollingReplacement {
    param(
        [Parameter(Mandatory)] [string] $SaveName,
        [Parameter(Mandatory)] [string[]] $KeepPaths
    )
    try {
        $folder = $script:Config.backupFolderPath
        if (-not (Test-Path -LiteralPath $folder)) { return }
        $keep = @{}
        foreach ($p in $KeepPaths) { $keep[(Get-FullBackupPath $p).ToLowerInvariant()] = $true }

        $points = @(Get-RollingBackupRestorePoints -Folder $folder)
        foreach ($point in $points) {
            if ($point.SaveName -ine $SaveName) { continue }
            foreach ($file in @($point.Files)) {
                $full = (Get-FullBackupPath $file.SourcePath).ToLowerInvariant()
                if ($keep.ContainsKey($full)) { continue }   # the backup we just wrote
                if (-not (Test-PathInsideBackupFolder -Path $file.SourcePath -Folder $folder)) { continue }
                if (Test-RetentionFileProtected -Path $file.SourcePath) {
                    Write-Log "Skipped rolling replacement for active restore source '$($file.SourcePath)'" 'WARN'
                    continue
                }
                if ($DryRun) {
                    Write-Log "[DRY-RUN] Would replace older rolling backup '$($file.SourcePath)'" 'DRYRUN'
                    continue
                }
                try {
                    Remove-Item -LiteralPath $file.SourcePath -Force
                    Write-Log "Replaced older rolling backup '$($file.SourcePath)'"
                }
                catch {
                    Write-Log "Failed to replace older rolling backup '$($file.SourcePath)': $($_.Exception.Message)" 'WARN'
                }
            }
        }
    }
    catch {
        Write-Log "Rolling replacement error: $($_.Exception.Message)" 'WARN'
    }
}

function Invoke-MilestoneRetention {
    param([string[]] $KeepPaths = @())

    try {
        $keep = 5
        if ($script:Config.PSObject.Properties.Name -contains 'keepMaxMilestones') {
            $keep = [int]$script:Config.keepMaxMilestones
        }
        elseif ($script:Config.PSObject.Properties.Name -contains 'keepMaxBackupsPerSave') {
            $keep = [int]$script:Config.keepMaxBackupsPerSave
        }
        if ($keep -lt 1) { return }

        $folder = $script:Config.milestoneFolderPath
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return }

        $keepMap = @{}
        foreach ($p in @($KeepPaths)) {
            if ($p) { $keepMap[(Get-FullBackupPath $p).ToLowerInvariant()] = $true }
        }

        $restorePoints = @(Get-RollingBackupRestorePoints -Folder $folder)
        if ($restorePoints.Count -le $keep) { return }

        $toDelete = @($restorePoints | Select-Object -Skip $keep)
        foreach ($point in $toDelete) {
            foreach ($file in @($point.Files)) {
                if (-not (Test-PathInsideBackupFolder -Path $file.SourcePath -Folder $folder)) { continue }
                $full = (Get-FullBackupPath $file.SourcePath).ToLowerInvariant()
                if ($keepMap.ContainsKey($full)) {
                    Write-Log "Skipped milestone retention delete for the newly created milestone '$($file.SourcePath)'" 'WARN'
                    continue
                }
                if (Test-RetentionFileProtected -Path $file.SourcePath) {
                    Write-Log "Skipped milestone retention delete for active restore source '$($file.SourcePath)'" 'WARN'
                    continue
                }

                if ($DryRun) {
                    Write-Log "[DRY-RUN] Would delete old milestone '$($file.SourcePath)'" 'DRYRUN'
                    continue
                }
                try {
                    Remove-Item -LiteralPath $file.SourcePath -Force
                    Write-Log "Deleted old milestone '$($file.SourcePath)'"
                }
                catch {
                    Write-Log "Failed to delete old milestone '$($file.SourcePath)': $($_.Exception.Message)" 'WARN'
                }
            }
        }
    }
    catch {
        Write-Log "Milestone retention error: $($_.Exception.Message)" 'WARN'
    }
}

# Back up ONE logical save group (the core routine used by manual and watch
# modes). When any file of a save changes, the whole group is re-scanned by base
# name so the matching .scop + .scoc (+ optional .dds) are always backed up
# together as a single restore point. StabilityAttempts controls how many times we
# wait/retry for the files to settle. The GUI poller passes 1 (it retries on the
# next poll) to stay responsive.
function Invoke-BackupGroup {
    param(
        [Parameter(Mandatory)] [string] $SaveName,
        [int] $StabilityAttempts = 5
    )

    # Re-scan the live folder for every file in this logical save group.
    $folder = $script:Config.saveFolderPath
    try {
        $groupFiles = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction Stop | Where-Object {
            ($script:Config.includeExtensions -contains $_.Extension.ToLowerInvariant()) -and
            ([System.IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $SaveName)
        })
    }
    catch {
        return
    }
    if ($groupFiles.Count -eq 0) { return }

    # Backup drive must be available (skipped for dry-run, which writes nothing).
    if (-not $DryRun -and -not (Test-BackupTargetAvailable)) {
        Write-Log "Backup target/drive unavailable; skipping '$SaveName'. (Is the backup drive connected?)" 'ERROR'
        return
    }

    # Never replace a complete backup with a partial write: if the game is still
    # writing the pair (only .scop or only .scoc present so far), wait for the
    # sibling on a later pass instead of backing up an incomplete save.
    if (-not (Test-SaveGroupComplete -Files $groupFiles)) {
        if ($StabilityAttempts -gt 1) {
            Write-Log "Save '$SaveName' is still being written (incomplete pair); will retry." 'WARN'
        }
        return
    }

    # Duplicate-protection: skip if this exact version of the group was already backed up.
    $signature = Get-SaveGroupSignature -Files $groupFiles
    if ($script:BackupCache.ContainsKey($SaveName) -and $script:BackupCache[$SaveName] -eq $signature) {
        return
    }

    # Wait until every file in the group is fully written (stable + unlocked).
    $ready = $false
    for ($attempt = 1; $attempt -le $StabilityAttempts; $attempt++) {
        $allReady = $true
        foreach ($file in $groupFiles) {
            if (-not (Test-FileReady $file.FullName)) { $allReady = $false; break }
        }
        if ($allReady) { $ready = $true; break }
        if ($StabilityAttempts -gt 1) {
            Write-Log "Save group not ready yet (locked or still being written): '$SaveName' (attempt $attempt/$StabilityAttempts)" 'WARN'
        }
        if ($attempt -lt $StabilityAttempts) { Start-Sleep -Seconds 1 }
    }
    if (-not $ready) {
        Write-Log "Save group not ready yet (locked/still saving); will retry: '$SaveName'" 'WARN'
        return
    }

    # Re-scan once more now that files are stable (sizes/timestamps settled).
    try {
        $groupFiles = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction Stop | Where-Object {
            ($script:Config.includeExtensions -contains $_.Extension.ToLowerInvariant()) -and
            ([System.IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $SaveName)
        })
    }
    catch {
        return
    }
    if ($groupFiles.Count -eq 0 -or -not (Test-SaveGroupComplete -Files $groupFiles)) { return }
    $signature = Get-SaveGroupSignature -Files $groupFiles

    # Minute-precision timestamp: seconds add noise and aren't needed now that
    # rolling backups replace the previous backup for each save name.
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'

    if ($DryRun) {
        Write-Log ("[DRY-RUN] Would back up save '{0}' ({1} file(s)) -> '{2}'" -f $SaveName, $groupFiles.Count, (Join-Path $script:Config.backupFolderPath ("{0}__{1}" -f $SaveName, $timestamp))) 'DRYRUN'
        $script:BackupCache[$SaveName] = $signature   # avoid repeated dry-run spam
        return
    }

    # Make sure the backup folder exists right before writing.
    try {
        Confirm-Directory $script:Config.backupFolderPath
    }
    catch {
        Write-Log "Could not create/access backup folder '$($script:Config.backupFolderPath)': $($_.Exception.Message)" 'ERROR'
        return
    }

    # Rolling backups overwrite the same-minute name (no collision suffix); the
    # replacement step below removes any older same-name backup afterwards.
    $written = New-SaveGroupBackup -SaveName $SaveName -Files $groupFiles -DestFolder $script:Config.backupFolderPath -Timestamp $timestamp

    if ($written) {
        Write-Log ("Backed up save '{0}' ({1} file(s)) -> '{2}'" -f $SaveName, @($written).Count, ($written -join '; ')) 'SUCCESS'
        $script:BackupCache[$SaveName] = $signature
        Invoke-RollingReplacement -SaveName $SaveName -KeepPaths @($written)
        Invoke-Retention -Base $SaveName -Ext '.scop'
    }
    else {
        Write-Log "Backup FAILED for save '$SaveName' (will retry on next change)." 'ERROR'
    }
}

# Back up the logical save group that a changed file belongs to. Thin wrapper kept
# so watch/poller call sites can pass a single file path; it resolves the base
# name and backs up the whole group (matching siblings included).
function Invoke-BackupForFile {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [int] $StabilityAttempts = 5
    )
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if ($script:Config.includeExtensions -notcontains $ext) { return }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    if ([string]::IsNullOrWhiteSpace($base)) { return }
    Invoke-BackupGroup -SaveName $base -StabilityAttempts $StabilityAttempts
}

# ===========================================================================
# Modes
# ===========================================================================

# Manual one-time backup of all current logical save groups.
function Invoke-BackupAll {
    $folder = $script:Config.saveFolderPath
    try {
        $groups = @(Get-LiveSaveGroups -Folder $folder)
    }
    catch {
        Write-Log "Could not list save folder '$folder': $($_.Exception.Message)" 'ERROR'
        return
    }

    if ($groups.Count -eq 0) {
        Write-Log "No matching save files found in '$folder'." 'INFO'
        return
    }

    Write-Log "Found $($groups.Count) logical save(s) to process." 'INFO'
    foreach ($group in $groups) {
        try {
            Invoke-BackupGroup -SaveName $group.SaveName
        }
        catch {
            Write-Log "Unexpected error backing up save '$($group.SaveName)': $($_.Exception.Message)" 'ERROR'
        }
    }
    Write-Log "One-time backup pass complete." 'INFO'
}

# Milestone snapshot: copies only the newest complete logical save group into
# the milestone folder with a shared minute-precision timestamp. If the newest
# live group is incomplete because the game is still writing, wait briefly and
# re-scan; if it remains incomplete, choose the newest complete group instead.
function Invoke-MilestoneBackup {
    $folder = $script:Config.saveFolderPath
    $dest   = $script:Config.milestoneFolderPath

    $selection = $null
    for ($scan = 1; $scan -le 2; $scan++) {
        try {
            $selection = Get-NewestCompleteLiveSaveGroup -Folder $folder
        }
        catch {
            Write-Log "Could not list save folder '$folder': $($_.Exception.Message)" 'ERROR'
            return
        }

        if (@($selection.Groups).Count -eq 0) {
            Write-Log "No matching save files found to milestone in '$folder'." 'WARN'
            return
        }

        if ($selection.Newest -and -not $selection.Newest.IsComplete -and $scan -eq 1) {
            Write-Log "Newest save '$($selection.Newest.SaveName)' is incomplete; waiting briefly before choosing a milestone." 'WARN'
            Start-Sleep -Seconds 1
            continue
        }

        break
    }

    $group = $selection.Complete
    if ($null -eq $group) {
        Write-Log "No complete logical save found for milestone. A complete save needs .scop + .scoc; .dds is optional." 'WARN'
        return
    }

    if ($selection.Newest -and $selection.Newest.SaveName -ine $group.SaveName) {
        Write-Log "Newest save '$($selection.Newest.SaveName)' is incomplete; milestone will use newest complete save '$($group.SaveName)'." 'WARN'
    }

    if (-not $DryRun) {
        if (-not (Test-BackupTargetAvailable)) {
            Write-Log "Backup drive/target unavailable; cannot write milestone. Connect the drive first." 'ERROR'
            return
        }
        try { Confirm-Directory $dest }
        catch { Write-Log "Could not create milestone folder '$dest': $($_.Exception.Message)" 'ERROR'; return }
    }

    $groupFiles = @($group.Files)

    if ($DryRun) {
        Write-Log ("[DRY-RUN] Would create milestone for newest complete save '{0}' ({1} file(s)) in '{2}'" -f $group.SaveName, $groupFiles.Count, $dest) 'DRYRUN'
        return
    }

    # Wait for every file in the group to be readable/stable (same safety as
    # normal backups) before snapshotting.
    $ready = $true
    foreach ($file in $groupFiles) {
        $fileReady = $false
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            if (Test-FileReady $file.FullName) { $fileReady = $true; break }
            Write-Log "File not ready for milestone: '$($file.FullName)' (attempt $attempt/5)" 'WARN'
            Start-Sleep -Seconds 1
        }
        if (-not $fileReady) { $ready = $false; break }
    }
    if (-not $ready) {
        Write-Log "Milestone skipped because newest complete save '$($group.SaveName)' is locked or still being written." 'ERROR'
        return
    }

    try {
        $groupFiles = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction Stop | Where-Object {
            ($script:Config.includeExtensions -contains $_.Extension.ToLowerInvariant()) -and
            ([System.IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $group.SaveName)
        })
    }
    catch {
        Write-Log "Could not re-scan save '$($group.SaveName)' before milestone: $($_.Exception.Message)" 'ERROR'
        return
    }
    if ($groupFiles.Count -eq 0 -or -not (Test-SaveGroupComplete -Files $groupFiles)) {
        Write-Log "Milestone skipped because save '$($group.SaveName)' is no longer a complete .scop + .scoc pair." 'WARN'
        return
    }

    # Minute precision keeps user-facing milestone names readable; collision
    # suffixes keep rapid same-minute milestones distinct.
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
    Write-Log ("Creating milestone from newest complete save '{0}' ({1} file(s)) in '{2}'." -f $group.SaveName, @($groupFiles).Count, $dest) 'INFO'

    $written = New-SaveGroupBackup -SaveName $group.SaveName -Files $groupFiles -DestFolder $dest -Timestamp $timestamp -UniqueCollision

    if ($written) {
        Write-Log ("Milestone saved '{0}' ({1} file(s)) -> '{2}'" -f $group.SaveName, @($written).Count, ($written -join '; ')) 'SUCCESS'
        Invoke-MilestoneRetention -KeepPaths @($written)
    }
    else {
        Write-Log "Milestone FAILED for save '$($group.SaveName)'." 'ERROR'
    }
}

# Continuous watch mode using FileSystemWatcher + a debounce buffer.
function Start-WatchMode {
    $folder = $script:Config.saveFolderPath

    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path                  = $folder
    $watcher.IncludeSubdirectories = $false
    $watcher.Filter                = '*.*'
    $watcher.NotifyFilter          = [System.IO.NotifyFilters]::LastWrite -bor `
                                     [System.IO.NotifyFilters]::FileName  -bor `
                                     [System.IO.NotifyFilters]::Size
    $watcher.EnableRaisingEvents   = $true

    # Route filesystem events into the PowerShell engine event queue so we can
    # drain them safely from this (main) thread.
    Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier 'SGB_Created' | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier 'SGB_Changed' | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier 'SGB_Renamed' | Out-Null

    Write-Log "Watching '$folder' for new/changed saves. Press Ctrl+C to stop." 'INFO'

    # path -> time of most recent event. A file is only processed once it has been
    # quiet for 'backupDelaySeconds'. This debounces the burst of events that the
    # watcher fires for a single save.
    $pending = @{}
    $delay   = [double]$script:Config.backupDelaySeconds

    try {
        while ($true) {
            $evt = Wait-Event -Timeout 1

            if ($evt) {
                # Drain ALL queued events in one go.
                $queued = @(Get-Event)
                foreach ($e in $queued) {
                    $path = $null
                    try { $path = $e.SourceEventArgs.FullPath } catch { }
                    if ($path) {
                        $eExt = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
                        if ($script:Config.includeExtensions -contains $eExt) {
                            $pending[$path] = Get-Date
                            if ($DryRun) {
                                $change = try { $e.SourceEventArgs.ChangeType } catch { 'Event' }
                                Write-Log "[DRY-RUN] Detected $change for '$path'" 'DRYRUN'
                            }
                        }
                    }
                    Remove-Event -EventIdentifier $e.EventIdentifier
                }
            }

            # Process files that have settled (no event for >= delay seconds).
            if ($pending.Count -gt 0) {
                $now   = Get-Date
                $ready = @($pending.Keys | Where-Object { ($now - $pending[$_]).TotalSeconds -ge $delay })
                foreach ($path in $ready) {
                    $pending.Remove($path)
                    try {
                        Invoke-BackupForFile $path
                    }
                    catch {
                        # Never let one bad file kill the watch loop.
                        Write-Log "Unexpected error processing '$path': $($_.Exception.Message)" 'ERROR'
                    }
                }
            }
        }
    }
    finally {
        Unregister-Event -SourceIdentifier 'SGB_Created' -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier 'SGB_Changed' -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier 'SGB_Renamed' -ErrorAction SilentlyContinue
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
        Write-Log "Watch mode stopped." 'INFO'
    }
}

# ===========================================================================
# Startup summary
# ===========================================================================
function Show-StartupSummary {
    param([string] $Mode)

    $dryState = if ($DryRun) { 'ENABLED (no files will be copied or deleted)' } else { 'disabled' }
    $zipState = if ($script:Config.enableZipBackup) { 'enabled (.zip backups)' } else { 'disabled (plain copies)' }
    $exts     = ($script:Config.includeExtensions -join ', ')

    Write-Host ''
    Write-Host '=====================================================' -ForegroundColor DarkCyan
    Write-Host ("   Anomaly Save Guardian  v{0}" -f $script:AppVersion) -ForegroundColor White
    Write-Host '=====================================================' -ForegroundColor DarkCyan
    Write-Host ("  Save folder      : {0}" -f $script:Config.saveFolderPath)
    Write-Host ("  Backup folder    : {0}" -f $script:Config.backupFolderPath)
    Write-Host ("  Milestone folder : {0}" -f $script:Config.milestoneFolderPath)
    Write-Host ("  Watched ext.     : {0}" -f $exts)
    Write-Host ("  Mode             : {0}" -f $Mode)
    Write-Host ("  Dry-run          : {0}" -f $dryState)
    Write-Host ("  Retention        : rolling {0}; milestones {1}" -f $script:Config.keepMaxBackupsPerSave, $script:Config.keepMaxMilestones)
    Write-Host ("  Zip backups      : {0}" -f $zipState)
    Write-Host ("  Backup delay     : {0} second(s)" -f $script:Config.backupDelaySeconds)
    Write-Host ("  Log file         : {0}" -f $script:Config.logFilePath)
    Write-Host '=====================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

# ===========================================================================
# Main
# ===========================================================================

# Library mode: stop here so callers can dot-source just the functions above.
if ($AsLibrary) { return }

# 1) Load + validate config from beside the script.
$scriptDir   = Get-ScriptDirectory
$configPath  = Join-Path $scriptDir 'stalker-gamma-backup-config.json'
$examplePath = Join-Path $scriptDir 'stalker-gamma-backup-config.example.json'

Initialize-ConfigIfMissing -ConfigPath $configPath -ExamplePath $examplePath

try {
    $script:Config = Import-BackupConfig -ConfigPath $configPath
}
catch {
    Write-Host "[CONFIG ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Fix '$configPath' and try again." -ForegroundColor Red
    exit 1
}

# 2) Decide mode.
if (-not $BackupNow -and -not $Watch -and -not $Milestone) {
    Write-Host 'Nothing to do. Choose a mode:' -ForegroundColor Yellow
    Write-Host '  .\backup-stalker-gamma-saves.ps1 -BackupNow          # one-time backup of all saves'
    Write-Host '  .\backup-stalker-gamma-saves.ps1 -Watch              # watch continuously'
    Write-Host '  .\backup-stalker-gamma-saves.ps1 -Milestone          # milestone newest complete save'
    Write-Host '  .\backup-stalker-gamma-saves.ps1 -BackupNow -DryRun  # preview one-time backup'
    Write-Host '  .\backup-stalker-gamma-saves.ps1 -Watch -DryRun      # preview watch mode'
    exit 0
}

$modeText = @()
if ($Milestone) { $modeText += 'Milestone snapshot' }
if ($BackupNow) { $modeText += 'One-time backup' }
if ($Watch)     { $modeText += 'Watch' }
Show-StartupSummary -Mode ($modeText -join ' + ')

# 3) Validate the save folder.
if (-not (Test-Path -LiteralPath $script:Config.saveFolderPath)) {
    Write-Log "Save folder does not exist: '$($script:Config.saveFolderPath)'. Check 'saveFolderPath' in the config." 'ERROR'
    exit 1
}
if (-not (Test-Path -LiteralPath $script:Config.saveFolderPath -PathType Container)) {
    Write-Log "Save folder path is not a folder: '$($script:Config.saveFolderPath)'." 'ERROR'
    exit 1
}

# 4) Check the backup drive / folder.
if (-not (Test-BackupTargetAvailable)) {
    $msg = "Backup drive/target is not available: '$($script:Config.backupFolderPath)'. Connect the drive (e.g. G:) first."
    if ($DryRun) {
        # Dry-run never writes, so let the preview continue even if the drive is offline.
        Write-Log "$msg (Dry-run: continuing preview anyway.)" 'WARN'
    }
    elseif (-not $Watch) {
        # One-time / milestone modes need the drive right now.
        Write-Log $msg 'ERROR'
        exit 1
    }
    else {
        # In watch mode we tolerate this: each backup re-checks availability,
        # so the drive can be reconnected later.
        Write-Log "$msg Watch mode will keep running and back up once it becomes available." 'WARN'
    }
}
else {
    # Pre-create the backup folder (and, indirectly, the log folder) when possible.
    if (-not $DryRun) {
        try { Confirm-Directory $script:Config.backupFolderPath }
        catch { Write-Log "Could not create backup folder '$($script:Config.backupFolderPath)': $($_.Exception.Message)" 'ERROR' }
    }
}

# 5) Run.
if ($Milestone) {
    Invoke-MilestoneBackup
}
if ($BackupNow) {
    Invoke-BackupAll
}
if ($Watch) {
    Start-WatchMode
}
