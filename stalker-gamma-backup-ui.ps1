<#
.SYNOPSIS
    Desktop app (GUI) for Anomaly Save Guardian.

.DESCRIPTION
    A small, dark-themed window that automatically backs up your STALKER GAMMA /
    Anomaly saves while you play. Start/stop watching, run a one-time backup, take
    a permanent milestone snapshot, restore a selected backup, change folders in
    Settings, and minimise to the system tray - all without a terminal.

    All real backup logic lives in 'backup-stalker-gamma-saves.ps1' (loaded here
    as a library). Settings are stored in 'stalker-gamma-backup-config.json'.

    Safe by design: your original saves are only ever read and copied - never
    modified, renamed, moved, or deleted.

.PARAMETER NoShow
    Build the window but do not display it (used for automated testing only).
#>
param([switch]$NoShow)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:SingleInstanceMutexName = 'Global\AnomalySaveGuardian_GAM33RSFR33AK'
$script:SingleInstanceMutex = $null
$script:SingleInstanceMutexAcquired = $false

function Show-SingleInstanceMessage {
    param([Parameter(Mandatory)] [string] $Message)

    if ($NoShow) {
        Write-Host $Message
        return
    }

    try {
        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            'Anomaly Save Guardian',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    catch {
        Write-Host $Message
    }
}

function Release-SingleInstanceGuard {
    if ($script:SingleInstanceMutex) {
        try {
            if ($script:SingleInstanceMutexAcquired) {
                $script:SingleInstanceMutex.ReleaseMutex()
            }
        }
        catch { }
        finally {
            $script:SingleInstanceMutexAcquired = $false
            $script:SingleInstanceMutex.Dispose()
            $script:SingleInstanceMutex = $null
        }
    }
}

function Initialize-SingleInstanceGuard {
    try {
        $script:SingleInstanceMutex = New-Object System.Threading.Mutex($false, $script:SingleInstanceMutexName)
        try {
            $script:SingleInstanceMutexAcquired = $script:SingleInstanceMutex.WaitOne(0, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            $script:SingleInstanceMutexAcquired = $true
        }
    }
    catch {
        Show-SingleInstanceMessage "Anomaly Save Guardian could not verify whether another instance is already running.`n`n$($_.Exception.Message)"
        Release-SingleInstanceGuard
        return $false
    }

    if (-not $script:SingleInstanceMutexAcquired) {
        Show-SingleInstanceMessage 'Anomaly Save Guardian is already running. Check the system tray.'
        Release-SingleInstanceGuard
        return $false
    }

    return $true
}

if (-not (Initialize-SingleInstanceGuard)) {
    return
}

# Encoding-safe glyphs (built by char code so the file stays ASCII-clean).
$symPlay = [string][char]0x25B6   # play  (start)
$symStop = [string][char]0x25A0   # stop
$symDot  = [string][char]0x25CF   # status dot
$symGear = [string][char]0x2699   # gear  (settings)
$symFlag = [string][char]0x2691   # flag  (milestone)

# ---------------------------------------------------------------------------
# Load the core backup engine as a library
# ---------------------------------------------------------------------------
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$corePath  = Join-Path $scriptDir 'backup-stalker-gamma-saves.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Could not find:`n$corePath`n`nKeep this app in the same folder as the backup script.",
        'Anomaly Save Guardian', 'OK', 'Error') | Out-Null
    Release-SingleInstanceGuard
    return
}
. $corePath -AsLibrary

$restoreCorePath = Join-Path $scriptDir 'restore-stalker-gamma-saves.ps1'
if (-not (Test-Path -LiteralPath $restoreCorePath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Could not find:`n$restoreCorePath`n`nKeep this app in the same folder as the restore helper.",
        'Anomaly Save Guardian', 'OK', 'Error') | Out-Null
    Release-SingleInstanceGuard
    return
}
. $restoreCorePath -AsLibrary

# ---------------------------------------------------------------------------
# Config (seed from example on first run, then load)
# ---------------------------------------------------------------------------
$script:ConfigPath = Join-Path $scriptDir 'stalker-gamma-backup-config.json'
$script:ExamplePath = Join-Path $scriptDir 'stalker-gamma-backup-config.example.json'

# Remember whether this is genuinely the first run (no personal config yet) so we
# can show friendly onboarding instead of dropping the user into a blank window.
$script:FirstRun = -not (Test-Path -LiteralPath $script:ConfigPath)

Initialize-ConfigIfMissing -ConfigPath $script:ConfigPath -ExamplePath $script:ExamplePath
try {
    $script:Config = Import-BackupConfig -ConfigPath $script:ConfigPath
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "There is a problem with the config file:`n`n$($_.Exception.Message)`n`nFile: $($script:ConfigPath)",
        'Anomaly Save Guardian', 'OK', 'Error') | Out-Null
    Release-SingleInstanceGuard
    return
}

# Shared state the core functions expect.
$DryRun              = $false
$script:BackupCache  = @{}
$script:Watching     = $false
$script:AppState     = 'Idle'
$script:LastBackupTime = $null

# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------
function C { param($r, $g, $b) [System.Drawing.Color]::FromArgb($r, $g, $b) }
function Shade {
    param($col, $amt)
    $r = [Math]::Max(0, [Math]::Min(255, [int]$col.R + $amt))
    $g = [Math]::Max(0, [Math]::Min(255, [int]$col.G + $amt))
    $b = [Math]::Max(0, [Math]::Min(255, [int]$col.B + $amt))
    [System.Drawing.Color]::FromArgb($r, $g, $b)
}

$cBg      = C 22 24 26
$cHeader  = C 16 18 19
$cCard    = C 32 35 37
$cCardHi  = C 40 44 46
$cLine    = C 52 56 58
$cText    = C 232 235 234
$cMuted   = C 150 156 154
$cFaint   = C 110 116 114
$cAccent  = C 132 204 72     # radioactive green
$cRed     = C 214 96 96
$cBlue    = C 86 146 206
$cAmber   = C 226 182 78
$cBlack   = [System.Drawing.Color]::Black
$cWhite   = [System.Drawing.Color]::White
$cLogBg   = C 15 16 17

$fTitle   = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$fTitle2  = New-Object System.Drawing.Font('Segoe UI', 13)
$fState   = New-Object System.Drawing.Font('Segoe UI', 13.5, [System.Drawing.FontStyle]::Bold)
$fSub     = New-Object System.Drawing.Font('Segoe UI', 8.5)
$fBtnBig  = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$fBtn     = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$fBody    = New-Object System.Drawing.Font('Segoe UI', 9)
$fBodyB   = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fSmall   = New-Object System.Drawing.Font('Segoe UI', 8)
$fMono    = New-Object System.Drawing.Font('Consolas', 9)

function New-Label {
    param($Text, $X, $Y, $W, $H, $Fore, $Font, $Align = 'TopLeft')
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.SetBounds($X, $Y, $W, $H)
    $l.ForeColor = $Fore; $l.Font = $Font
    $l.TextAlign = $Align
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.UseMnemonic = $false   # so '&' in paths/headers renders literally
    return $l
}
function New-Panel {
    param($X, $Y, $W, $H, $Back)
    $p = New-Object System.Windows.Forms.Panel
    $p.SetBounds($X, $Y, $W, $H); $p.BackColor = $Back
    return $p
}
function New-Button {
    param($Text, $X, $Y, $W, $H, $Back, $Fore, $Font = $fBtn)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.SetBounds($X, $Y, $W, $H)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back; $b.ForeColor = $Fore; $b.Font = $Font
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.FlatAppearance.MouseOverBackColor = (Shade $Back 18)
    $b.FlatAppearance.MouseDownBackColor = (Shade $Back -12)
    $b.UseVisualStyleBackColor = $false
    return $b
}

# A small "pill" label used for the backup-rule summary on the main window. Width
# is fitted to its text in Set-Badge so several read cleanly on one row.
function New-Badge {
    param($X, $Y, $Back, $Fore)
    $l = New-Object System.Windows.Forms.Label
    $l.SetBounds($X, $Y, 10, 20)
    $l.BackColor = $Back; $l.ForeColor = $Fore
    $l.Font = $fSmall
    $l.TextAlign = 'MiddleCenter'
    $l.UseMnemonic = $false
    return $l
}
function Set-Badge {
    param($Label, [string]$Text)
    $Label.Text  = $Text
    $Label.Width = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $Label.Font).Width + 18
}

# Shared tooltip provider (created early so Update-Info can attach path tooltips).
$script:Tip = New-Object System.Windows.Forms.ToolTip
$script:Tip.AutoPopDelay = 20000
$script:Tip.InitialDelay = 350
$script:Tip.ReshowDelay  = 120

# Middle-truncate text so long paths fit a fixed-width label (full value in tooltip).
function Get-FittedText {
    param([string]$Text, $Font, [int]$MaxWidth)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ([System.Windows.Forms.TextRenderer]::MeasureText($Text, $Font).Width -le $MaxWidth) { return $Text }
    $ell = [string][char]0x2026   # single-glyph ellipsis
    for ($keep = $Text.Length - 1; $keep -ge 6; $keep--) {
        $head = [int][Math]::Ceiling($keep / 2.0)
        $tail = $keep - $head
        $cand = $Text.Substring(0, $head) + $ell + $Text.Substring($Text.Length - $tail)
        if ([System.Windows.Forms.TextRenderer]::MeasureText($cand, $Font).Width -le $MaxWidth) { return $cand }
    }
    return $Text
}
function Set-PathLabel {
    param($Label, [string]$Path)
    $full = if ([string]::IsNullOrWhiteSpace($Path)) { '(not set yet)' } else { $Path }
    $Label.Text = Get-FittedText -Text $full -Font $Label.Font -MaxWidth $Label.Width
    $script:Tip.SetToolTip($Label, $full)
}

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Anomaly Save Guardian'
$form.ClientSize      = New-Object System.Drawing.Size(700, 640)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = $cBg
$form.Font            = $fBody
$form.KeyPreview      = $true

$icoPath = Join-Path $scriptDir 'anomaly-save-guardian.ico'
if (Test-Path -LiteralPath $icoPath) { try { $form.Icon = New-Object System.Drawing.Icon $icoPath } catch { } }

# --- Header ---
$header  = New-Panel 0 0 700 72 $cHeader
$hAccent = New-Panel 0 0 700 3 $cAccent
$hTitle1 = New-Label 'ANOMALY'        18 13 130 28 $cAccent $fTitle
$hTitle2 = New-Label 'SAVE GUARDIAN' 150 18 200 24 $cText   $fTitle2
$hSub    = New-Label 'Automatic save protection - never lose a run' 20 45 440 16 $cMuted $fSub
$hVer    = New-Label ("v{0}" -f $script:AppVersion) 596 14 90 18 $cFaint $fSmall 'TopRight'
$header.Controls.AddRange(@($hAccent, $hTitle1, $hTitle2, $hSub, $hVer))
$form.Controls.Add($header)

# --- Status card ---
$cardStatus  = New-Panel 16 82 668 70 $cCard
$accentStrip = New-Panel 0 0 5 70 $cMuted
$dot         = New-Label $symDot 16 23 20 24 $cMuted (New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold))
$stateTitle  = New-Label 'Idle' 40 11 400 24 $cMuted $fState
$stateSub    = New-Label '' 42 39 480 18 $cMuted $fBody
$lblDrive    = New-Label '' 470 13 188 18 $cMuted $fSmall 'TopRight'
$cardStatus.Controls.AddRange(@($accentStrip, $dot, $stateTitle, $stateSub, $lblDrive))
$form.Controls.Add($cardStatus)

# --- Info card (folders + rules) ---
$cardInfo = New-Panel 16 162 668 92 $cCard
$kSave  = New-Label 'Saves'    16 13 86 18 $cMuted $fBody
$kBak   = New-Label 'Backups'  16 39 86 18 $cMuted $fBody
$kRule  = New-Label 'Rules'    16 65 86 18 $cMuted $fBody
$lblSaveVal = New-Label '' 104 13 548 18 $cText $fBody
$lblBakVal  = New-Label '' 104 39 548 18 $cText $fBody
# Backup rules shown as three readable "pills" instead of one long line that clipped.
$badgeRoll = New-Badge 104 63 $cCardHi $cAccent
$badgeMile = New-Badge 104 63 $cCardHi $cBlue
$badgeZip  = New-Badge 104 63 $cCardHi $cAmber
$cardInfo.Controls.AddRange(@($kSave, $kBak, $kRule, $lblSaveVal, $lblBakVal, $badgeRoll, $badgeMile, $badgeZip))
$form.Controls.Add($cardInfo)

# --- Primary action ---
$btnToggle = New-Button "$symPlay   Start Watching" 16 266 668 52 $cAccent $cBlack $fBtnBig
$btnToggle.TabIndex = 0
$form.Controls.Add($btnToggle)

# --- Secondary actions ---
$btnNow     = New-Button 'Backup Now'               16  330 124 42 $cCard $cText
$btnMile    = New-Button "$symFlag  Milestone"      152 330 124 42 $cBlue $cWhite
$btnRestore = New-Button 'Restore Backup'           288 330 124 42 $cAmber $cBlack
$btnOpen    = New-Button 'Open Folder'              424 330 124 42 $cCard $cText
$btnSet     = New-Button "$symGear  Settings"       560 330 124 42 $cCard $cText
$btnNow.TabIndex = 1; $btnMile.TabIndex = 2; $btnRestore.TabIndex = 3; $btnOpen.TabIndex = 4; $btnSet.TabIndex = 5
$form.Controls.AddRange(@($btnNow, $btnMile, $btnRestore, $btnOpen, $btnSet))

# --- Activity header ---
$lblAct    = New-Label 'ACTIVITY' 16 388 200 18 $cMuted $fBodyB
$btnClear   = New-Button 'Clear'          614 384 70  26 $cCard $cMuted $fSmall
$btnClear.TabIndex = 6

# --- Activity log ---
$log = New-Object System.Windows.Forms.RichTextBox
$log.SetBounds(16, 410, 668, 188)
$log.ReadOnly = $true
$log.BackColor = $cLogBg
$log.ForeColor = $cText
$log.Font = $fMono
$log.BorderStyle = 'None'
$log.HideSelection = $false
$log.TabIndex = 7
$form.Controls.AddRange(@($lblAct, $btnClear, $log))

# --- Footer ---
$footer   = New-Panel 0 610 700 30 $cHeader
$creatorCredit = 'Created by GAM33RSFR33AK'
$lblFootBy = New-Label 'Created by' 16 7 64 16 $cFaint $fSmall
$lblFootName = New-Label 'GAM33RSFR33AK' 88 7 150 16 $cFaint $fSmall
$lblFootR = New-Label 'Originals are never modified' 454 7 230 16 $cFaint $fSmall 'TopRight'
$footer.Controls.AddRange(@($lblFootBy, $lblFootName, $lblFootR))
$form.Controls.Add($footer)

# ---------------------------------------------------------------------------
# Tooltips
# ---------------------------------------------------------------------------
$script:Tip.SetToolTip($btnToggle, 'Start or stop automatic backups. While watching, every new or changed save is copied the moment it appears.')
$script:Tip.SetToolTip($btnNow,    'Back up all current saves once, right now.')
$script:Tip.SetToolTip($btnMile,   'Creates a milestone from the newest complete save.')
$script:Tip.SetToolTip($btnRestore,'Choose a backup, review what will be restored, create a safety backup, then copy it back into the save folder.')
$script:Tip.SetToolTip($btnOpen,   'Open the backup folder in Windows Explorer.')
$script:Tip.SetToolTip($btnSet,    'Choose your save folder, backup folder and backup rules. No JSON editing needed.')
$script:Tip.SetToolTip($btnClear,  'Clear the on-screen activity log (does not touch any files).')
$script:Tip.SetToolTip($lblDrive,  'Status of the drive that holds your backup folder.')

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
function Add-LogLine {
    param($line, $level)
    $color = switch ($level) {
        'ERROR'   { $cRed }
        'WARN'    { $cAmber }
        'SUCCESS' { $cAccent }
        'DRYRUN'  { $cBlue }
        'HINT'    { $cFaint }
        default   { $cMuted }
    }
    $log.SelectionStart = $log.TextLength
    $log.SelectionColor = $color
    $log.AppendText("$line`r`n")
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
    if ($log.Lines.Count -gt 600) {
        $log.Select(0, $log.GetFirstCharIndexFromLine(200)); $log.SelectedText = ''
    }
}

# Mirror engine log lines into the on-screen log, and remember the last successful
# backup so the status area can show a reassuring "last backup at HH:mm:ss".
$script:LogSink = {
    param($line, $level)
    if ($level -eq 'SUCCESS' -and ($line -like '*Backed up*' -or $line -like '*Milestone saved*')) {
        $script:LastBackupTime = Get-Date
    }
    Add-LogLine $line $level
}

# The single source of truth for what the status area shows.
function Set-AppState {
    param(
        [ValidateSet('Idle', 'Watching', 'WaitingDrive', 'BackingUp', 'Error')] [string] $State,
        [string] $Detail
    )
    switch ($State) {
        'Idle'         { $col = $cMuted;  $title = 'Idle';                      $sub = 'Not watching. Click "Start Watching" to protect your saves.' }
        'Watching'     { $col = $cAccent; $title = 'Watching';                  $sub = 'Protecting saves - complete save groups are backed up as you play.' }
        'WaitingDrive' { $col = $cAmber;  $title = 'Waiting for backup drive';  $sub = 'Reconnect the backup drive - backups resume automatically.' }
        'BackingUp'    { $col = $cBlue;   $title = 'Backing up...';             $sub = 'Copying your latest saves to the backup folder.' }
        'Error'        { $col = $cRed;    $title = 'Needs attention';           $sub = 'Something went wrong - see the activity log below.' }
    }
    if ($State -eq 'Watching' -and $script:LastBackupTime) {
        $sub = ('Protected - last backup at {0}.' -f $script:LastBackupTime.ToString('HH:mm:ss'))
    }
    if ($Detail) { $sub = $Detail }

    $script:AppState       = $State
    $stateTitle.Text       = $title
    $stateTitle.ForeColor  = $col
    $stateSub.Text         = $sub
    $dot.ForeColor         = $col
    $accentStrip.BackColor = $col
    if ($script:Notify) { $script:Notify.Text = "Anomaly Save Guardian - $title" }
}

function Update-Info {
    Set-PathLabel $lblSaveVal $script:Config.saveFolderPath
    Set-PathLabel $lblBakVal  $script:Config.backupFolderPath
    $keepRoll = [int]$script:Config.keepMaxBackupsPerSave
    $mileKeep = if ($script:Config.PSObject.Properties.Name -contains 'keepMaxMilestones') { [int]$script:Config.keepMaxMilestones } else { 5 }
    $zipText  = if ($script:Config.enableZipBackup) { 'Zip: one save group' } else { 'Zip: off' }

    # Lay the rule pills out left to right, fitting each to its own text.
    $x = 104
    Set-Badge $badgeRoll 'Rolling: newest per save name'
    $badgeRoll.Location = New-Object System.Drawing.Point($x, 63); $x = $badgeRoll.Right + 8
    Set-Badge $badgeMile ("Milestones: newest complete, keep {0}" -f $mileKeep)
    $badgeMile.Location = New-Object System.Drawing.Point($x, 63); $x = $badgeMile.Right + 8
    Set-Badge $badgeZip $zipText
    $badgeZip.Location  = New-Object System.Drawing.Point($x, 63)
    $badgeZip.ForeColor = if ($script:Config.enableZipBackup) { $cAmber } else { $cFaint }

    $rulesTip = "File types backed up: $($script:Config.includeExtensions -join ' ')`r`nA restore point is a complete save group: .scop + .scoc required, .dds optional.`r`nRolling keeps the newest $keepRoll backups per save name (older ones are replaced).`r`nMilestone backs up the newest complete save and keeps the latest $mileKeep restore points.`r`nZip mode stores each complete save group as one .zip when enabled."
    $script:Tip.SetToolTip($badgeRoll, $rulesTip)
    $script:Tip.SetToolTip($badgeMile, $rulesTip)
    $script:Tip.SetToolTip($badgeZip,  $rulesTip)
    $script:Tip.SetToolTip($kRule,     $rulesTip)
    $lblFootBy.Text = 'Created by'
    $lblFootName.Text = 'GAM33RSFR33AK'
    $script:Tip.SetToolTip($lblFootBy, $creatorCredit)
    $script:Tip.SetToolTip($lblFootName, $creatorCredit)
}

function Show-EmptyLogHint {
    Add-LogLine '  Activity and backups will appear here while you play.' 'HINT'
}

Update-Info
Set-AppState 'Idle'

# ---------------------------------------------------------------------------
# Watcher (polls the save folder - responsive and reliable inside a GUI)
# ---------------------------------------------------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.add_Tick({
    if (-not $script:Watching) { return }
    try {
        if (-not (Test-BackupTargetAvailable)) {
            Set-AppState 'WaitingDrive'
            $lblDrive.Text = 'drive: offline'; $lblDrive.ForeColor = $cAmber
            return
        }
        $lblDrive.Text = 'drive: ready'; $lblDrive.ForeColor = $cAccent
        $files = @(Get-ChildItem -LiteralPath $script:Config.saveFolderPath -File |
                   Where-Object { $script:Config.includeExtensions -contains $_.Extension.ToLowerInvariant() })
        foreach ($f in $files) { Invoke-BackupForFile -FilePath $f.FullName -StabilityAttempts 1 }
        Set-AppState 'Watching'
    }
    catch {
        Write-Log "Watch error: $($_.Exception.Message)" 'ERROR'
        Set-AppState 'Error'
    }
})

function Start-Watch {
    if (-not (Test-Path -LiteralPath $script:Config.saveFolderPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Your save folder was not found:`n$($script:Config.saveFolderPath)`n`nOpen Settings and point ""Save folder"" at your STALKER Anomaly / GAMMA savedgames folder.",
            'Save folder not found', 'OK', 'Warning') | Out-Null
        Write-Log "Cannot start watching: save folder not found ($($script:Config.saveFolderPath))." 'ERROR'
        return
    }
    if (-not (Test-BackupTargetAvailable)) {
        Write-Log "Backup drive not available yet - watching will start saving once it is connected." 'WARN'
    }
    $script:Watching = $true
    $timer.Start()
    $btnToggle.Text = "$symStop   Stop Watching"; $btnToggle.BackColor = $cRed; $btnToggle.ForeColor = $cWhite
    Set-AppState 'Watching'
    if ($script:TrayToggle) { $script:TrayToggle.Text = "$symStop  Stop Watching" }
    Write-Log "Watch mode started - protecting your saves." 'INFO'
}
function Stop-Watch {
    $script:Watching = $false
    $timer.Stop()
    $btnToggle.Text = "$symPlay   Start Watching"; $btnToggle.BackColor = $cAccent; $btnToggle.ForeColor = $cBlack
    Set-AppState 'Idle'
    $lblDrive.Text = ''
    if ($script:TrayToggle) { $script:TrayToggle.Text = "$symPlay  Start Watching" }
    Write-Log "Watch mode stopped." 'INFO'
}

# Run a synchronous backup action while showing a transient "Backing up..." state.
function Invoke-WithBackingUpState {
    param([scriptblock] $Action)
    Set-AppState 'BackingUp'
    [System.Windows.Forms.Application]::DoEvents()
    try { & $Action }
    finally {
        if ($script:Watching) { Set-AppState 'Watching' } else { Set-AppState 'Idle' }
    }
}

# ---------------------------------------------------------------------------
# Settings dialog
# ---------------------------------------------------------------------------
function Show-SettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Settings'
    $dlg.ClientSize = New-Object System.Drawing.Size(600, 601)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $cBg; $dlg.Font = $fBody
    if ($form.Icon) { $dlg.Icon = $form.Icon }

    function Add-Section {
        param($text, $y)
        $dlg.Controls.Add((New-Label $text 20 $y 560 18 $cAccent $fBodyB))
        $dlg.Controls.Add((New-Panel 20 ($y + 20) 560 1 $cLine))
    }
    function Add-Field {
        param($label, $y, $value, $browse, $help)
        # Label is vertically centered against the field (MiddleLeft) and the field
        # height is fixed (AutoSize off) with enough room that the text is not
        # clipped at the top/bottom when Windows display scaling enlarges the font.
        $dlg.Controls.Add((New-Label $label 20 $y 100 28 $cMuted $fBody 'MiddleLeft'))
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.AutoSize = $false
        $tb.SetBounds(124, $y, $(if ($browse) { 374 } else { 456 }), 28)
        $tb.BackColor = $cCardHi; $tb.ForeColor = $cText; $tb.BorderStyle = 'FixedSingle'
        $tb.Text = [string]$value
        $dlg.Controls.Add($tb)
        if ($browse) {
            $b = New-Button 'Browse' 506 ($y - 1) 74 28 $cCard $cText $fSmall
            $b.Tag = $tb; $b.Add_Click($browse)
            $dlg.Controls.Add($b)
        }
        if ($help) {
            $dlg.Controls.Add((New-Label $help 124 ($y + 30) 456 16 $cFaint $fSmall))
        }
        return $tb
    }

    $pickFolder = {
        $tb = $this.Tag
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($tb.Text -and (Test-Path -LiteralPath $tb.Text)) { $d.SelectedPath = $tb.Text }
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $tb.Text = $d.SelectedPath }
    }
    $pickFile = {
        $tb = $this.Tag
        $d = New-Object System.Windows.Forms.SaveFileDialog
        $d.Filter = 'Log file (*.txt;*.log)|*.txt;*.log|All files (*.*)|*.*'
        $d.OverwritePrompt = $false
        if ($tb.Text) {
            try { $d.InitialDirectory = Split-Path -Parent $tb.Text; $d.FileName = Split-Path -Leaf $tb.Text } catch { }
        }
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $tb.Text = $d.FileName }
    }

    # --- FOLDERS ---
    Add-Section 'FOLDERS' 16
    $tbSave = Add-Field 'Save folder'      50  $script:Config.saveFolderPath      $pickFolder 'Your STALKER Anomaly / GAMMA "appdata\savedgames" folder (the source).'
    $tbBak  = Add-Field 'Backup folder'    100 $script:Config.backupFolderPath    $pickFolder 'Where rolling backups are written. A second drive is recommended.'
    $tbMile = Add-Field 'Milestone folder' 150 $script:Config.milestoneFolderPath $pickFolder 'Milestone backs up the newest complete save. Blank = a "Milestones" subfolder.'

    # --- BACKUP BEHAVIOR ---
    Add-Section 'BACKUP BEHAVIOR' 212
    $tbExt = Add-Field 'File types' 246 ($script:Config.includeExtensions -join ' ') $null 'One save = .scop + .scoc required; .dds optional. The whole group is backed up together.'

    # Small whole-number field. A plain TextBox (digit-only) is used instead of a
    # NumericUpDown: the dark-themed NumericUpDown clipped its value against the
    # border, while a TextBox renders cleanly like every other field. Values are
    # parsed and range-clamped on Save.
    function New-NumBox {
        param($X, $Y, $W, $Value)
        $t = New-Object System.Windows.Forms.TextBox
        $t.BackColor = $cCardHi; $t.ForeColor = $cText; $t.BorderStyle = 'FixedSingle'
        $t.TextAlign = 'Center'; $t.MaxLength = 6
        $t.Text = [string]$Value
        # AutoSize off + a fixed height with vertical breathing room so the digits
        # are not clipped when Windows display scaling enlarges the font.
        $t.AutoSize = $false
        $t.SetBounds($X, $Y, $W, 28)
        $t.Add_KeyPress({ param($s, $e)
            if (-not [char]::IsControl($e.KeyChar) -and -not [char]::IsDigit($e.KeyChar)) { $e.Handled = $true } })
        return $t
    }

    $dlg.Controls.Add((New-Label 'Keep rolling' 20 305 100 28 $cMuted $fBody 'MiddleLeft'))
    $numKeep = New-NumBox 124 305 70 ([int]$script:Config.keepMaxBackupsPerSave)

    $dlg.Controls.Add((New-Label 'Keep milestones' 246 305 110 28 $cMuted $fBody 'MiddleLeft'))
    $mileKeep = if ($script:Config.PSObject.Properties.Name -contains 'keepMaxMilestones') { [int]$script:Config.keepMaxMilestones } else { 5 }
    $numMile = New-NumBox 360 305 70 $mileKeep
    $dlg.Controls.Add((New-Label 'Rolling replaces by save name; milestones keep latest restore points. Default: 5.' 124 336 456 16 $cFaint $fSmall))

    $chkZip = New-Object System.Windows.Forms.CheckBox
    $chkZip.Text = 'Store each complete save group as one .zip'
    $chkZip.SetBounds(122, 367, 360, 22)
    $chkZip.ForeColor = $cText; $chkZip.BackColor = [System.Drawing.Color]::Transparent
    $chkZip.Checked = [bool]$script:Config.enableZipBackup
    $dlg.Controls.Add($chkZip)
    $dlg.Controls.Add((New-Label 'Zip mode stores each complete save group as one .zip; .dds is optional.' 124 393 456 16 $cFaint $fSmall))

    # --- ADVANCED & LOGGING ---
    Add-Section 'ADVANCED & LOGGING' 429
    $tbLog = Add-Field 'Log file' 463 $script:Config.logFilePath $pickFile 'Where the text log is written. Handy if you ever need to see what happened.'

    # --- Validation summary + buttons ---
    $lblErr = New-Label '' 20 517 560 28 $cRed $fSmall
    $dlg.Controls.Add($lblErr)

    $numKeep.TabIndex = 10; $numMile.TabIndex = 11; $chkZip.TabIndex = 12
    $dlg.Controls.AddRange(@($numKeep, $numMile))

    $btnReset  = New-Button 'Reset to defaults' 20  557 160 32 $cCard   $cMuted $fSmall
    $btnSave   = New-Button 'Save'              340 557 116 32 $cAccent $cBlack
    $btnCancel = New-Button 'Cancel'            464 557 116 32 $cCard   $cText
    $dlg.Controls.AddRange(@($btnReset, $btnSave, $btnCancel))

    $script:Tip.SetToolTip($btnReset, 'Reload the fields from the bundled example. Nothing is saved until you click Save.')
    $script:Tip.SetToolTip($numKeep, 'Rolling backups replace the previous backup with the same save name. Default: 5.')
    $script:Tip.SetToolTip($numMile, 'Milestone backs up the newest complete save and keeps the latest milestone restore points. Default: 5.')
    $script:Tip.SetToolTip($chkZip, 'Zip mode stores each complete save group as one .zip. The .dds thumbnail is optional.')

    $btnReset.Add_Click({
        if ([System.Windows.Forms.MessageBox]::Show(
                'Reset all fields to the example defaults? Nothing is saved until you click Save.',
                'Reset to defaults', 'YesNo', 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        try {
            $ex = Import-BackupConfig -ConfigPath $script:ExamplePath
            $tbSave.Text = $ex.saveFolderPath; $tbBak.Text = $ex.backupFolderPath
            $tbMile.Text = $ex.milestoneFolderPath; $tbLog.Text = $ex.logFilePath
            $tbExt.Text  = ($ex.includeExtensions -join ' ')
            $numKeep.Text  = [string][Math]::Min(100000, [Math]::Max(1, [int]$ex.keepMaxBackupsPerSave))
            $numMile.Text  = [string][Math]::Min(100000, [Math]::Max(1, [int]$ex.keepMaxMilestones))
            $chkZip.Checked = [bool]$ex.enableZipBackup
            $lblErr.ForeColor = $cMuted; $lblErr.Text = 'Fields reset to example defaults. Review them, then click Save.'
        }
        catch {
            $lblErr.ForeColor = $cRed; $lblErr.Text = "Could not read the example config: $($_.Exception.Message)"
        }
    })

    $btnCancel.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })

    $btnSave.Add_Click({
        $lblErr.ForeColor = $cRed
        $save = $tbSave.Text.Trim(); $bak = $tbBak.Text.Trim()
        $mile = $tbMile.Text.Trim(); $logp = $tbLog.Text.Trim()

        # Hard validation (block save).
        if (-not $save -or -not $bak -or -not $logp) {
            $lblErr.Text = 'Save folder, Backup folder and Log file are all required.'
            return
        }
        $exts = @($tbExt.Text -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object {
            $x = $_.Trim().ToLowerInvariant(); if (-not $x.StartsWith('.')) { $x = ".$x" }; $x })
        if ($exts.Count -eq 0) {
            $lblErr.Text = 'Enter at least one file type, e.g.  .scop .scoc .dds'
            return
        }
        if ($save -eq $bak) {
            $lblErr.Text = 'The Save folder and Backup folder must be different.'
            return
        }

        # Whole-number fields: parse, then range-clamp to safe values.
        $keepVal = 0; $mileVal = 0
        if (-not [int]::TryParse($numKeep.Text.Trim(), [ref]$keepVal)) {
            $lblErr.Text = 'Keep rolling must be a whole number (e.g. 5).'; return
        }
        if (-not [int]::TryParse($numMile.Text.Trim(), [ref]$mileVal)) {
            $lblErr.Text = 'Keep milestones must be a whole number (e.g. 5).'; return
        }
        $keepVal  = [Math]::Min(100000, [Math]::Max(1, $keepVal))
        $mileVal  = [Math]::Min(100000, [Math]::Max(1, $mileVal))
        $numKeep.Text = [string]$keepVal; $numMile.Text = [string]$mileVal

        # Soft validation (warn, but allow - the drive may simply be offline now).
        $warnings = @()
        if (-not (Test-Path -LiteralPath $save -PathType Container)) {
            $warnings += "- The Save folder does not exist yet:`n  $save"
        }
        try {
            $bakQual = Split-Path -Qualifier $bak
            if ($bakQual -and -not (Test-Path -LiteralPath "$bakQual\")) {
                $warnings += "- The Backup folder's drive ($bakQual) is not connected right now."
            }
        } catch { }
        if ($warnings.Count -gt 0) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                ("Heads up:`n`n{0}`n`nSave these settings anyway?" -f ($warnings -join "`n`n")),
                'Check your folders', 'YesNo', 'Warning')
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { $lblErr.Text = 'Not saved - adjust the folders above.'; return }
        }

        if (-not $mile) { $mile = Join-Path $bak 'Milestones' }
        $newCfg = [PSCustomObject]@{
            saveFolderPath        = $save
            backupFolderPath      = $bak
            milestoneFolderPath   = $mile
            includeExtensions     = $exts
            backupDelaySeconds    = 5   # fixed, built-in settle delay (no longer user-editable)
            keepMaxBackupsPerSave = [int]$keepVal
            keepMaxMilestones     = [int]$mileVal
            enableZipBackup       = [bool]$chkZip.Checked
            logFilePath           = $logp
        }
        try {
            Save-BackupConfig -Config $newCfg -Path $script:ConfigPath
            $script:Config = Import-BackupConfig -ConfigPath $script:ConfigPath
            $script:BackupCache = @{}   # paths may have changed; re-evaluate from scratch
            Update-Info
            if (-not $script:Watching) { Set-AppState 'Idle' }
            Write-Log 'Settings saved.' 'SUCCESS'
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        }
        catch {
            $lblErr.Text = "Could not save settings: $($_.Exception.Message)"
        }
    })

    $dlg.AcceptButton = $btnSave
    $dlg.CancelButton = $btnCancel
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

# ---------------------------------------------------------------------------
# Restore dialog
# ---------------------------------------------------------------------------
function Show-RestoreDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Restore Backup'
    $dlg.ClientSize = New-Object System.Drawing.Size(820, 620)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $cBg; $dlg.Font = $fBody
    if ($form.Icon) { $dlg.Icon = $form.Icon }

    $dlg.Controls.Add((New-Label 'Restore Backup' 18 14 240 26 $cAccent $fState))
    $dlg.Controls.Add((New-Label 'Choose backup -> review -> safety backup -> restore complete' 18 42 500 18 $cMuted $fBody))

    $dlg.Controls.Add((New-Label 'Find save' 18 76 80 20 $cMuted $fBody))
    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.SetBounds(86, 73, 248, 24)
    $txtFilter.BackColor = $cCardHi; $txtFilter.ForeColor = $cText; $txtFilter.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($txtFilter)

    $btnRefresh = New-Button 'Refresh' 346 70 90 28 $cCard $cText $fSmall
    $btnOpen2 = New-Button 'Open Backup Folder' 448 70 150 28 $cCard $cText $fSmall
    $dlg.Controls.AddRange(@($btnRefresh, $btnOpen2))

    $list = New-Object System.Windows.Forms.ListView
    $list.SetBounds(18, 110, 480, 426)
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect = $false
    $list.HideSelection = $false
    $list.BackColor = $cLogBg
    $list.ForeColor = $cText
    $list.BorderStyle = 'None'
    [void]$list.Columns.Add('Save name', 130)
    [void]$list.Columns.Add('Backup time', 128)
    [void]$list.Columns.Add('Type', 72)
    [void]$list.Columns.Add('Status', 88)
    [void]$list.Columns.Add('Files', 44)
    $dlg.Controls.Add($list)

    $previewTitle = New-Label 'Review selected backup' 520 76 270 22 $cAccent $fBodyB
    $preview = New-Object System.Windows.Forms.RichTextBox
    $preview.SetBounds(520, 110, 282, 426)
    $preview.ReadOnly = $true
    $preview.BorderStyle = 'None'
    $preview.BackColor = $cLogBg
    $preview.ForeColor = $cText
    $preview.Font = $fBody
    $preview.Text = 'Select a backup on the left to see what will be restored.'
    $dlg.Controls.AddRange(@($previewTitle, $preview))

    $lblResult = New-Label '' 18 548 514 28 $cMuted $fSmall
    $btnRestoreSelected = New-Button 'Restore Selected' 538 552 142 36 $cAccent $cBlack
    $btnClose = New-Button 'Close' 694 552 108 36 $cCard $cText
    $btnRestoreSelected.Enabled = $false
    $dlg.Controls.AddRange(@($lblResult, $btnRestoreSelected, $btnClose))

    $script:RestoreDialogPoints = @()

    function Get-RestoreDialogSelection {
        if ($list.SelectedItems.Count -eq 0) { return $null }
        return $list.SelectedItems[0].Tag
    }

    function Get-RestoreDialogTimeText {
        param([string] $Stamp)
        # Minute-precision rolling backups (yyyy-MM-dd_HH-mm) and second-precision
        # milestone / older backups (yyyy-MM-dd_HH-mm-ss) are both supported.
        foreach ($fmt in @('yyyy-MM-dd_HH-mm-ss', 'yyyy-MM-dd_HH-mm')) {
            try {
                $dt = [datetime]::ParseExact($Stamp, $fmt, [Globalization.CultureInfo]::InvariantCulture)
                $outFmt = if ($fmt -like '*ss') { 'yyyy-MM-dd HH:mm:ss' } else { 'yyyy-MM-dd HH:mm' }
                return $dt.ToString($outFmt)
            }
            catch { }
        }
        return $Stamp
    }

    function Update-RestorePreview {
        $point = Get-RestoreDialogSelection
        if (-not $point) {
            $preview.ForeColor = $cText
            $preview.Text = 'Select a backup on the left to see what will be restored.'
            $btnRestoreSelected.Enabled = $false
            return
        }

        $lines = @()
        $lines += "Save: $($point.SaveName)"
        $lines += "Backup: $(Get-RestoreDialogTimeText $point.Timestamp)"
        $lines += "Type: $($point.Type)"
        $lines += "Status: $($point.Status)"
        if (-not $point.IsComplete) {
            $lines += ''
            $lines += 'This backup is missing the required .scop + .scoc pair.'
            $lines += 'Restore is blocked for this backup.'
        }
        $lines += ''
        $lines += 'Files to restore:'
        foreach ($file in @($point.Files | Sort-Object Extension)) {
            $dest = try { Get-RestoreDestinationPath -Config $script:Config -DestinationName $file.DestinationName } catch { Join-Path $script:Config.saveFolderPath $file.DestinationName }
            $kind = if ($file.IsZip) { 'zip backup' } else { 'backup file' }
            $lines += ("- {0} ({1:N0} bytes, {2})" -f $file.DestinationName, $file.Size, $kind)
            $lines += "  From: $($file.SourcePath)"
            $lines += "  To:   $dest"
        }

        $overwrites = @()
        foreach ($file in @($point.Files)) {
            try {
                $dest = Get-RestoreDestinationPath -Config $script:Config -DestinationName $file.DestinationName
                if (Test-Path -LiteralPath $dest -PathType Leaf) { $overwrites += $dest }
            }
            catch { }
        }
        $lines += ''
        $lines += 'Live files that will be overwritten:'
        if ($overwrites.Count -gt 0) {
            foreach ($path in $overwrites) { $lines += "- $path" }
        }
        else {
            $lines += '- None found right now.'
        }

        $safeName = $point.SaveName -replace '[^\w.\- ]', '_'
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'save' }
        $lines += ''
        $lines += 'Pre-restore safety backup:'
        $lines += (Join-Path (Join-Path $script:Config.backupFolderPath 'PreRestoreSafetyBackups') "yyyy-MM-dd_HH-mm-ss_restore_$safeName")
        $lines += ''
        $lines += 'Close the game before restoring. Backup files will not be modified or deleted.'

        $preview.ForeColor = if ($point.IsComplete) { $cText } else { $cAmber }
        $preview.Text = ($lines -join "`r`n")
        $btnRestoreSelected.Enabled = [bool]$point.IsComplete
    }

    function Refresh-RestoreList {
        $lblResult.ForeColor = $cMuted
        $lblResult.Text = 'Scanning backups...'
        [System.Windows.Forms.Application]::DoEvents()
        $list.BeginUpdate()
        try {
            $list.Items.Clear()
            $script:RestoreDialogPoints = @(Get-RestorePoints -Config $script:Config)
            $filter = $txtFilter.Text.Trim()
            $visible = @($script:RestoreDialogPoints | Where-Object {
                -not $filter -or $_.SaveName.IndexOf($filter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            })
            foreach ($point in $visible) {
                $item = New-Object System.Windows.Forms.ListViewItem($point.SaveName)
                [void]$item.SubItems.Add((Get-RestoreDialogTimeText $point.Timestamp))
                [void]$item.SubItems.Add($point.Type)
                [void]$item.SubItems.Add($point.Status)
                [void]$item.SubItems.Add([string]$point.FileCount)
                $item.Tag = $point
                if (-not $point.IsComplete) { $item.ForeColor = $cAmber }
                [void]$list.Items.Add($item)
            }
            $lblResult.Text = if ($visible.Count -eq 1) { 'Found 1 restore point.' } else { "Found $($visible.Count) restore points." }
            if ($list.Items.Count -gt 0) { $list.Items[0].Selected = $true }
            Update-RestorePreview
        }
        catch {
            $lblResult.ForeColor = $cRed
            $lblResult.Text = "Could not scan backups: $($_.Exception.Message)"
            $preview.ForeColor = $cRed
            $preview.Text = $lblResult.Text
            $btnRestoreSelected.Enabled = $false
        }
        finally {
            $list.EndUpdate()
        }
    }

    $txtFilter.Add_TextChanged({ Refresh-RestoreList })
    $list.Add_SelectedIndexChanged({ Update-RestorePreview })
    $btnRefresh.Add_Click({ Refresh-RestoreList })
    $btnOpen2.Add_Click({
        try {
            if (Test-Path -LiteralPath $script:Config.backupFolderPath) {
                Start-Process explorer.exe -ArgumentList $script:Config.backupFolderPath
            } else {
                [System.Windows.Forms.MessageBox]::Show('Backup folder is not available (is the drive connected?).', 'Restore Backup', 'OK', 'Warning') | Out-Null
            }
        } catch { }
    })

    $btnRestoreSelected.Add_Click({
        $point = Get-RestoreDialogSelection
        if (-not $point) { return }
        $running = @(Get-RunningGameProcessNames)
        $gameLine = if ($running.Count -gt 0) {
            "The game may be running: $($running -join ', '). Close it before restoring."
        }
        else {
            'Close the game completely before restoring.'
        }
        $confirmText = @"
$gameLine

The selected backup will be copied into your live save folder.
Existing matching live files will be overwritten.
Anomaly Save Guardian will first create a pre-restore safety backup.
No backup files will be modified or deleted.

Restore "$($point.SaveName)" from $($point.Type) backup $($point.Timestamp)?
"@
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $confirmText,
            'Confirm restore',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $lblResult.ForeColor = $cMuted
            $lblResult.Text = 'Restore cancelled.'
            return
        }

        $btnRestoreSelected.Enabled = $false
        $btnRefresh.Enabled = $false
        $lblResult.ForeColor = $cMuted
        $lblResult.Text = 'Creating safety backup and restoring...'
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $result = Invoke-RestorePoint -Config $script:Config -RestorePoint $point -Confirmed
            $lblResult.ForeColor = $cAccent
            $lblResult.Text = "Restore complete. Safety backup: $($result.SafetyBackupFolder)"
            Write-Log "Restore complete for '$($point.SaveName)'. Safety backup: $($result.SafetyBackupFolder)" 'SUCCESS'
            [System.Windows.Forms.MessageBox]::Show(
                "Restore complete.`n`nSafety backup created at:`n$($result.SafetyBackupFolder)`n`nYou can now start the game and load the save.",
                'Restore complete', 'OK', 'Information') | Out-Null
            Refresh-RestoreList
        }
        catch {
            $lblResult.ForeColor = $cRed
            $lblResult.Text = "Restore failed: $($_.Exception.Message)"
            Write-Log "Restore failed: $($_.Exception.Message)" 'ERROR'
            [System.Windows.Forms.MessageBox]::Show(
                "Restore failed:`n`n$($_.Exception.Message)`n`nNo backup files were modified or deleted.",
                'Restore failed', 'OK', 'Error') | Out-Null
            Update-RestorePreview
        }
        finally {
            $btnRefresh.Enabled = $true
            $btnRestoreSelected.Enabled = [bool]((Get-RestoreDialogSelection) -and (Get-RestoreDialogSelection).IsComplete)
        }
    })

    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.AcceptButton = $btnClose
    $dlg.CancelButton = $btnClose
    Refresh-RestoreList
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

# ---------------------------------------------------------------------------
# First-run / onboarding welcome
# ---------------------------------------------------------------------------
function Test-NeedsSetup {
    $save = $script:Config.saveFolderPath
    return (-not $save -or -not (Test-Path -LiteralPath $save -PathType Container))
}

function Show-WelcomeDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Welcome'
    $dlg.ClientSize = New-Object System.Drawing.Size(520, 372)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $cBg; $dlg.Font = $fBody
    if ($form.Icon) { $dlg.Icon = $form.Icon }

    $dlg.Controls.Add((New-Panel 0 0 520 4 $cAccent))
    $dlg.Controls.Add((New-Label 'Welcome, stalker' 24 24 472 28 $cAccent $fTitle))
    $dlg.Controls.Add((New-Label "Let's protect your STALKER GAMMA / Anomaly saves. It takes about a minute:" 24 58 472 18 $cText $fBody))

    $steps = New-Object System.Windows.Forms.RichTextBox
    $steps.SetBounds(24, 88, 472, 150)
    $steps.ReadOnly = $true; $steps.BorderStyle = 'None'
    $steps.BackColor = $cBg; $steps.ForeColor = $cText; $steps.Font = $fBody
    $steps.Text = @"
1.  Pick your save folder - your Anomaly / GAMMA "appdata\savedgames" folder.

2.  Pick a backup folder - ideally on a second drive, so a disk failure
    can't take your saves and backups at once.

3.  Click "Start Watching" - every new or changed save is then copied
    automatically while you play.
"@
    $dlg.Controls.Add($steps)

    $safe = New-Panel 24 244 472 56 $cCard
    $safe.Controls.Add((New-Label 'Safe by design' 14 8 200 16 $cAccent $fBodyB))
    $safe.Controls.Add((New-Label 'Your saves are only ever read and copied - never changed, moved, or deleted.' 14 28 446 18 $cMuted $fSmall))
    $dlg.Controls.Add($safe)

    $btnSetup = New-Button 'Choose folders now' 24  316 200 36 $cAccent $cBlack
    $btnLater = New-Button 'Skip for now'       400 316 96  36 $cCard   $cText
    $dlg.Controls.AddRange(@($btnSetup, $btnLater))
    $btnSetup.Add_Click({ $dlg.Tag = 'setup'; $dlg.Close() })
    $btnLater.Add_Click({ $dlg.Tag = 'later'; $dlg.Close() })
    $dlg.AcceptButton = $btnSetup
    $dlg.CancelButton = $btnLater
    [void]$dlg.ShowDialog($form)
    $choice = $dlg.Tag
    $dlg.Dispose()
    if ($choice -eq 'setup') { Show-SettingsDialog }
}

# ---------------------------------------------------------------------------
# Button actions
# ---------------------------------------------------------------------------
$btnToggle.Add_Click({ if ($script:Watching) { Stop-Watch } else { Start-Watch } })

$btnNow.Add_Click({
    $btnNow.Enabled = $false
    try {
        if (Test-BackupTargetAvailable) {
            Write-Log 'Manual one-time backup requested.' 'INFO'
            Invoke-WithBackingUpState { Invoke-BackupAll }
        }
        else { Write-Log 'Backup drive not available - connect it first.' 'ERROR' }
    } catch { Write-Log "Backup Now failed: $($_.Exception.Message)" 'ERROR' }
    finally { $btnNow.Enabled = $true }
})

$btnMile.Add_Click({
    $btnMile.Enabled = $false
    try {
        if (Test-BackupTargetAvailable) {
            Invoke-WithBackingUpState { Invoke-MilestoneBackup }
        }
        else { Write-Log 'Backup drive not available - connect it first.' 'ERROR' }
    } catch { Write-Log "Milestone failed: $($_.Exception.Message)" 'ERROR' }
    finally { $btnMile.Enabled = $true }
})

$btnOpen.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $script:Config.backupFolderPath) -and (Test-BackupTargetAvailable)) {
            Confirm-Directory $script:Config.backupFolderPath
        }
        if (Test-Path -LiteralPath $script:Config.backupFolderPath) {
            Start-Process explorer.exe -ArgumentList $script:Config.backupFolderPath
        } else { Write-Log 'Backup folder is not available (is the drive connected?).' 'WARN' }
    } catch { Write-Log "Could not open folder: $($_.Exception.Message)" 'ERROR' }
})

$btnSet.Add_Click({ Show-SettingsDialog })
$btnRestore.Add_Click({ Show-RestoreDialog })
$btnClear.Add_Click({ $log.Clear(); Show-EmptyLogHint })

# ---------------------------------------------------------------------------
# System tray
# ---------------------------------------------------------------------------
function Show-Window {
    $form.Show(); $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.ShowInTaskbar = $true; [void]$form.Activate()
}
function Hide-ToTray {
    $form.Hide(); $form.ShowInTaskbar = $false
    if (-not $script:TrayHintShown) {
        $script:Notify.ShowBalloonTip(2500, 'Still backing up',
            'The backup app is in the system tray. Double-click the icon to reopen it.',
            [System.Windows.Forms.ToolTipIcon]::Info)
        $script:TrayHintShown = $true
    }
}

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$script:TrayToggle = $trayMenu.Items.Add("$symPlay  Start Watching")
$script:TrayToggle.Add_Click({ if ($script:Watching) { Stop-Watch } else { Start-Watch } })
$miNow = $trayMenu.Items.Add('Backup Now')
$miNow.Add_Click({
    try { if (Test-BackupTargetAvailable) { Write-Log 'Manual one-time backup requested.' 'INFO'; Invoke-BackupAll }
          else { Write-Log 'Backup drive not available - connect it first.' 'ERROR' } }
    catch { Write-Log "Backup Now failed: $($_.Exception.Message)" 'ERROR' }
})
$miMile = $trayMenu.Items.Add('Take Milestone')
$miMile.Add_Click({
    try { if (Test-BackupTargetAvailable) { Invoke-MilestoneBackup }
          else { Write-Log 'Backup drive not available - connect it first.' 'ERROR' } }
    catch { Write-Log "Milestone failed: $($_.Exception.Message)" 'ERROR' }
})
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miShow = $trayMenu.Items.Add('Show Window'); $miShow.Add_Click({ Show-Window })
$miExit = $trayMenu.Items.Add('Exit');        $miExit.Add_Click({ $script:ReallyExit = $true; $form.Close() })

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
try {
    if (Test-Path -LiteralPath $icoPath) { $script:Notify.Icon = New-Object System.Drawing.Icon $icoPath }
    elseif ($form.Icon)                  { $script:Notify.Icon = $form.Icon }
    else                                 { $script:Notify.Icon = [System.Drawing.SystemIcons]::Application }
} catch { $script:Notify.Icon = [System.Drawing.SystemIcons]::Application }
$script:Notify.Text             = 'Anomaly Save Guardian - Idle'
$script:Notify.ContextMenuStrip = $trayMenu
$script:Notify.Visible          = $true
$script:Notify.Add_DoubleClick({ Show-Window })
$script:TrayHintShown = $false
$script:ReallyExit    = $false

# Minimize OR close (X) -> hide to tray. Only tray -> Exit truly quits.
$form.Add_Resize({ if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { Hide-ToTray } })
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:ReallyExit -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true; Hide-ToTray; return
    }
    $script:Watching = $false; $timer.Stop()
})
$form.Add_FormClosed({
    try { if ($script:Notify) { $script:Notify.Visible = $false; $script:Notify.Dispose() } } catch { }
    Release-SingleInstanceGuard
})

# Show onboarding once the window is up, on first run or if setup looks incomplete.
$form.Add_Shown({
    if ($script:FirstRun -or (Test-NeedsSetup)) {
        Show-WelcomeDialog
    }
})

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------
Write-Log "Ready - settings loaded from config." 'INFO'
Write-Log "Click 'Start Watching' to auto-backup every save while you play." 'INFO'
Write-Log "Use 'Take Milestone' to back up the newest complete save as a milestone." 'INFO'
Write-Log "Closing the X keeps the app running in the system tray." 'INFO'
Show-EmptyLogHint

$script:Form = $form
if (-not $NoShow) {
    [System.Windows.Forms.Application]::Run($form)
}
else {
    Write-Host 'UI constructed successfully (NoShow).'
    try { if ($script:Notify) { $script:Notify.Visible = $false; $script:Notify.Dispose() } } catch { }
    Release-SingleInstanceGuard
}
