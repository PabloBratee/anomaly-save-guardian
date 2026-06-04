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
    Take a PERMANENT snapshot of all current save files into the milestone
    folder. Milestone backups are NEVER deleted by retention cleanup - use this
    to lock in an "I'm alive here" point before something risky.

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
$script:BackupCache = @{}            # path -> "lastWriteTicks|length" of last backup made

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
    # subfolder inside the backup folder. Retention never touches this folder.
    $milestone = $null
    if (($present -contains 'milestoneFolderPath') -and -not [string]::IsNullOrWhiteSpace($cfg.milestoneFolderPath)) {
        $milestone = [string]$cfg.milestoneFolderPath
    }
    else {
        $milestone = Join-Path ([string]$cfg.backupFolderPath) 'Milestones'
    }

    # Return a clean, typed object.
    return [PSCustomObject]@{
        saveFolderPath        = [string]$cfg.saveFolderPath
        backupFolderPath      = [string]$cfg.backupFolderPath
        milestoneFolderPath   = $milestone
        includeExtensions     = $normExt
        backupDelaySeconds    = $delay
        keepMaxBackupsPerSave = $keep
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
    $ordered = [ordered]@{
        saveFolderPath        = [string]$Config.saveFolderPath
        backupFolderPath      = [string]$Config.backupFolderPath
        milestoneFolderPath   = [string]$Config.milestoneFolderPath
        includeExtensions     = @($Config.includeExtensions)
        backupDelaySeconds    = $Config.backupDelaySeconds
        keepMaxBackupsPerSave = [int]$Config.keepMaxBackupsPerSave
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

# Create a timestamped .zip containing the single save file. Source is read-only.
function New-ZipBackup {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $DestinationZip
    )
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $DestinationZip) {
            Remove-Item -LiteralPath $DestinationZip -Force
        }
        $zip = [System.IO.Compression.ZipFile]::Open($DestinationZip, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $Source, [System.IO.Path]::GetFileName($Source)) | Out-Null
        }
        finally {
            $zip.Dispose()
        }
        return $true
    }
    catch [System.UnauthorizedAccessException] {
        Write-Log "Permission denied creating zip for '$Source': $($_.Exception.Message)" 'ERROR'
        return $false
    }
    catch {
        Write-Log "Zip backup failed for '$Source': $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# Retention: for one original save (base name + extension), keep only the newest
# N backups in the backup folder and delete the rest. Conservative + scoped to
# the backup folder only. NEVER touches the save folder.
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

        # Match exactly the naming scheme this script produces for this save.
        if ($script:Config.enableZipBackup) {
            $pattern = "${Base}__*${Ext}.zip"
        }
        else {
            $pattern = "${Base}__*${Ext}"
        }

        # -like (not -Filter) avoids the legacy 8.3 wildcard quirk where "*.sav"
        # can also match longer extensions.
        #
        # Sort by NAME, not LastWriteTime: Copy-Item preserves the source file's
        # timestamp, so every backup of an unchanged save would share the same
        # LastWriteTime and the sort could delete the newest copy. The embedded
        # "__YYYY-MM-DD_HH-mm-ss" timestamp sorts chronologically as text, so a
        # descending name sort reliably puts the newest backups first.
        $backups = @(Get-ChildItem -LiteralPath $folder -File |
                     Where-Object { $_.Name -like $pattern } |
                     Sort-Object Name -Descending)

        if ($backups.Count -le $keep) { return }

        $toDelete = $backups | Select-Object -Skip $keep
        foreach ($file in $toDelete) {
            # SAFETY: only ever delete files physically inside the backup folder.
            if ($file.FullName -notlike (Join-Path $folder '*')) { continue }

            if ($DryRun) {
                Write-Log "[DRY-RUN] Would delete old backup '$($file.FullName)'" 'DRYRUN'
                continue
            }
            try {
                Remove-Item -LiteralPath $file.FullName -Force
                Write-Log "Deleted old backup '$($file.FullName)'"
            }
            catch {
                Write-Log "Failed to delete old backup '$($file.FullName)': $($_.Exception.Message)" 'WARN'
            }
        }
    }
    catch {
        Write-Log "Retention error for '${Base}${Ext}': $($_.Exception.Message)" 'WARN'
    }
}

# Back up a single file (the core routine used by both manual and watch modes).
# StabilityAttempts controls how many times we wait/retry for a file to settle.
# The GUI poller passes 1 (it just retries on the next poll) to stay responsive.
function Invoke-BackupForFile {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [int] $StabilityAttempts = 5
    )

    # Extension filter
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if ($script:Config.includeExtensions -notcontains $ext) { return }

    # File may have vanished between event and processing
    if (-not (Test-Path -LiteralPath $FilePath)) { return }

    # Backup drive must be available (skipped for dry-run, which writes nothing).
    if (-not $DryRun -and -not (Test-BackupTargetAvailable)) {
        Write-Log "Backup target/drive unavailable; skipping '$FilePath'. (Is the backup drive connected?)" 'ERROR'
        return
    }

    # Debounce / duplicate-protection: skip if this exact version was already backed up.
    try {
        $item = Get-Item -LiteralPath $FilePath
    }
    catch {
        return  # file disappeared
    }
    $signature = "$($item.LastWriteTimeUtc.Ticks)|$($item.Length)"
    if ($script:BackupCache.ContainsKey($FilePath) -and $script:BackupCache[$FilePath] -eq $signature) {
        return
    }

    # Wait until the file is fully written (stable size + not locked), with retries.
    $ready = $false
    for ($attempt = 1; $attempt -le $StabilityAttempts; $attempt++) {
        if (Test-FileReady $FilePath) { $ready = $true; break }
        if ($StabilityAttempts -gt 1) {
            Write-Log "File not ready (locked or still being written): '$FilePath' (attempt $attempt/$StabilityAttempts)" 'WARN'
        }
        if ($attempt -lt $StabilityAttempts) { Start-Sleep -Seconds 1 }
    }
    if (-not $ready) {
        Write-Log "File not ready yet (locked/still saving); will retry: '$FilePath'" 'WARN'
        return
    }

    # Recompute signature now that the file is stable.
    try {
        $item = Get-Item -LiteralPath $FilePath
    }
    catch {
        return
    }
    $signature = "$($item.LastWriteTimeUtc.Ticks)|$($item.Length)"

    # Build the destination name: OriginalSaveName__YYYY-MM-DD_HH-mm-ss.ext
    $base      = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    if ($script:Config.enableZipBackup) {
        $destName = "${base}__${timestamp}${ext}.zip"
    }
    else {
        $destName = "${base}__${timestamp}${ext}"
    }
    $destPath = Join-Path $script:Config.backupFolderPath $destName

    if ($DryRun) {
        Write-Log "[DRY-RUN] Would back up '$FilePath' -> '$destPath'" 'DRYRUN'
        $script:BackupCache[$FilePath] = $signature   # avoid repeated dry-run spam
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

    $ok = if ($script:Config.enableZipBackup) {
        New-ZipBackup -Source $FilePath -DestinationZip $destPath
    }
    else {
        Copy-SaveFile -Source $FilePath -Destination $destPath
    }

    if ($ok) {
        Write-Log "Backed up '$FilePath' -> '$destPath'" 'SUCCESS'
        $script:BackupCache[$FilePath] = $signature
        Invoke-Retention -Base $base -Ext $ext
    }
    else {
        Write-Log "Backup FAILED for '$FilePath' (will retry on next change)." 'ERROR'
    }
}

# ===========================================================================
# Modes
# ===========================================================================

# Manual one-time backup of all current save files.
function Invoke-BackupAll {
    $folder = $script:Config.saveFolderPath
    try {
        $files = @(Get-ChildItem -LiteralPath $folder -File |
                   Where-Object { $script:Config.includeExtensions -contains $_.Extension.ToLowerInvariant() })
    }
    catch {
        Write-Log "Could not list save folder '$folder': $($_.Exception.Message)" 'ERROR'
        return
    }

    if ($files.Count -eq 0) {
        Write-Log "No matching save files found in '$folder'." 'INFO'
        return
    }

    Write-Log "Found $($files.Count) save file(s) to process." 'INFO'
    foreach ($file in $files) {
        try {
            Invoke-BackupForFile $file.FullName
        }
        catch {
            Write-Log "Unexpected error backing up '$($file.FullName)': $($_.Exception.Message)" 'ERROR'
        }
    }
    Write-Log "One-time backup pass complete." 'INFO'
}

# Permanent milestone snapshot: copies ALL current save files into the milestone
# folder with a single shared timestamp. These are NEVER deleted by retention
# (retention only scans the top level of the backup folder, not subfolders / the
# milestone folder). Use before anything risky in a lives-limited run.
function Invoke-MilestoneBackup {
    $folder = $script:Config.saveFolderPath
    $dest   = $script:Config.milestoneFolderPath

    try {
        $files = @(Get-ChildItem -LiteralPath $folder -File |
                   Where-Object { $script:Config.includeExtensions -contains $_.Extension.ToLowerInvariant() })
    }
    catch {
        Write-Log "Could not list save folder '$folder': $($_.Exception.Message)" 'ERROR'
        return
    }

    if ($files.Count -eq 0) {
        Write-Log "No matching save files found to snapshot in '$folder'." 'WARN'
        return
    }

    if (-not $DryRun) {
        if (-not (Test-BackupTargetAvailable)) {
            Write-Log "Backup drive/target unavailable; cannot write milestone. Connect the drive first." 'ERROR'
            return
        }
        try { Confirm-Directory $dest }
        catch { Write-Log "Could not create milestone folder '$dest': $($_.Exception.Message)" 'ERROR'; return }
    }

    # One shared timestamp so the whole save set is grouped as a single moment.
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    Write-Log "Creating PERMANENT milestone snapshot ($($files.Count) file(s)) in '$dest'." 'INFO'

    foreach ($file in $files) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($file.FullName)
        $ext  = $file.Extension.ToLowerInvariant()
        if ($script:Config.enableZipBackup) {
            $destName = "${base}__${timestamp}${ext}.zip"
        }
        else {
            $destName = "${base}__${timestamp}${ext}"
        }
        $destPath = Join-Path $dest $destName

        if ($DryRun) {
            Write-Log "[DRY-RUN] Would create milestone '$($file.FullName)' -> '$destPath'" 'DRYRUN'
            continue
        }

        # Wait for the file to be readable/stable (same safety as normal backups).
        $ready = $false
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            if (Test-FileReady $file.FullName) { $ready = $true; break }
            Write-Log "File not ready for milestone: '$($file.FullName)' (attempt $attempt/5)" 'WARN'
            Start-Sleep -Seconds 1
        }
        if (-not $ready) {
            Write-Log "Skipping locked/unstable file for milestone: '$($file.FullName)'" 'ERROR'
            continue
        }

        $ok = if ($script:Config.enableZipBackup) {
            New-ZipBackup -Source $file.FullName -DestinationZip $destPath
        }
        else {
            Copy-SaveFile -Source $file.FullName -Destination $destPath
        }

        if ($ok) {
            Write-Log "Milestone saved '$($file.FullName)' -> '$destPath'" 'SUCCESS'
        }
        else {
            Write-Log "Milestone FAILED for '$($file.FullName)'." 'ERROR'
        }
    }
    Write-Log "Milestone snapshot complete (these are never auto-deleted)." 'INFO'
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
    Write-Host ("   STALKER GAMMA Save Backup  v{0}" -f $script:AppVersion) -ForegroundColor White
    Write-Host '=====================================================' -ForegroundColor DarkCyan
    Write-Host ("  Save folder      : {0}" -f $script:Config.saveFolderPath)
    Write-Host ("  Backup folder    : {0}" -f $script:Config.backupFolderPath)
    Write-Host ("  Milestone folder : {0}" -f $script:Config.milestoneFolderPath)
    Write-Host ("  Watched ext.     : {0}" -f $exts)
    Write-Host ("  Mode             : {0}" -f $Mode)
    Write-Host ("  Dry-run          : {0}" -f $dryState)
    Write-Host ("  Retention        : keep newest {0} per save" -f $script:Config.keepMaxBackupsPerSave)
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
    Write-Host '  .\backup-stalker-gamma-saves.ps1 -Milestone          # permanent snapshot (never auto-deleted)'
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
