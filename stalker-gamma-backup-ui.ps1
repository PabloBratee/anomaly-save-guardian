<#
.SYNOPSIS
    Desktop app (GUI) for STALKER GAMMA Save Backup.

.DESCRIPTION
    A small, dark-themed window that automatically backs up your STALKER GAMMA
    saves while you play. Start/stop watching, run a one-time backup, take a
    permanent milestone snapshot, change folders in Settings, and minimise to the
    system tray - all without a terminal.

    All real backup logic lives in 'backup-stalker-gamma-saves.ps1' (loaded here
    as a library). Settings are stored in 'stalker-gamma-backup-config.json'.

.PARAMETER NoShow
    Build the window but do not display it (used for automated testing only).
#>
param([switch]$NoShow)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Encoding-safe glyphs.
$symPlay = [string][char]0x25B6   # play
$symStop = [string][char]0x25A0   # stop
$symDot  = [string][char]0x25CF   # status dot
$symGear = [string][char]0x2699   # gear

# ---------------------------------------------------------------------------
# Load the core backup engine as a library
# ---------------------------------------------------------------------------
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$corePath  = Join-Path $scriptDir 'backup-stalker-gamma-saves.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Could not find:`n$corePath`n`nKeep this app in the same folder as the backup script.",
        'STALKER GAMMA Save Backup', 'OK', 'Error') | Out-Null
    return
}
. $corePath -AsLibrary

# ---------------------------------------------------------------------------
# Config (seed from example on first run, then load)
# ---------------------------------------------------------------------------
$script:ConfigPath = Join-Path $scriptDir 'stalker-gamma-backup-config.json'
$examplePath       = Join-Path $scriptDir 'stalker-gamma-backup-config.example.json'
Initialize-ConfigIfMissing -ConfigPath $script:ConfigPath -ExamplePath $examplePath
try {
    $script:Config = Import-BackupConfig -ConfigPath $script:ConfigPath
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "There is a problem with the config file:`n`n$($_.Exception.Message)`n`nFile: $($script:ConfigPath)",
        'STALKER GAMMA Save Backup', 'OK', 'Error') | Out-Null
    return
}

# Shared state the core functions expect.
$DryRun             = $false
$script:BackupCache = @{}
$script:Watching    = $false

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
$cText    = C 232 235 234
$cMuted   = C 148 154 152
$cAccent  = C 132 204 72     # radioactive green
$cRed     = C 208 84 84
$cBlue    = C 86 146 206
$cAmber   = C 222 178 74
$cBlack   = [System.Drawing.Color]::Black
$cWhite   = [System.Drawing.Color]::White

$fTitle   = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$fSub     = New-Object System.Drawing.Font('Segoe UI', 8.5)
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
    return $b
}

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'STALKER GAMMA Save Backup'
$form.ClientSize      = New-Object System.Drawing.Size(680, 620)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = $cBg
$form.Font            = $fBody

$icoPath = Join-Path $scriptDir 'stalker-gamma-backup.ico'
if (Test-Path -LiteralPath $icoPath) { try { $form.Icon = New-Object System.Drawing.Icon $icoPath } catch { } }

# --- Header ---
$header = New-Panel 0 0 680 64 $cHeader
$hTitle1 = New-Label 'STALKER GAMMA' 16 11 230 26 $cAccent $fTitle
$hTitle2 = New-Label 'SAVE BACKUP'   228 16 220 24 $cText  (New-Object System.Drawing.Font('Segoe UI', 13))
$hSub    = New-Label 'Automatic save protection - never lose a run' 18 40 420 16 $cMuted $fSub
$hVer    = New-Label ("v{0}" -f $script:AppVersion) 580 12 84 18 $cMuted $fSmall 'TopRight'
$header.Controls.AddRange(@($hTitle1, $hTitle2, $hSub, $hVer))
$form.Controls.Add($header)

# --- Status card ---
$cardStatus = New-Panel 16 80 648 50 $cCard
$dot    = New-Label $symDot 12 12 22 24 $cMuted (New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold))
$status = New-Label 'Idle' 36 15 360 22 $cMuted $fBodyB
$lblDrive = New-Label '' 430 15 206 22 $cMuted $fBody 'TopRight'
$cardStatus.Controls.AddRange(@($dot, $status, $lblDrive))
$form.Controls.Add($cardStatus)

# --- Info card ---
$cardInfo = New-Panel 16 138 648 96 $cCard
$kSave  = New-Label 'Saves'    14 12 90 18 $cMuted $fBody
$kBak   = New-Label 'Backups'  14 38 90 18 $cMuted $fBody
$kWatch = New-Label 'Watching' 14 64 90 18 $cMuted $fBody
$lblSaveVal  = New-Label '' 108 12 528 18 $cText $fBody
$lblBakVal   = New-Label '' 108 38 528 18 $cText $fBody
$lblWatchVal = New-Label '' 108 64 528 18 $cText $fBody
$cardInfo.Controls.AddRange(@($kSave, $kBak, $kWatch, $lblSaveVal, $lblBakVal, $lblWatchVal))
$form.Controls.Add($cardInfo)

# --- Primary action ---
$btnToggle = New-Button "$symPlay   Start Watching" 16 246 648 50 $cAccent $cBlack (New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold))
$form.Controls.Add($btnToggle)

# --- Secondary actions ---
$btnNow  = New-Button 'Backup Now'      16  306 156 40 $cCard $cText
$btnMile = New-Button 'Take Milestone'  180 306 156 40 $cBlue $cWhite
$btnOpen = New-Button 'Open Folder'     344 306 156 40 $cCard $cText
$btnSet  = New-Button "$symGear  Settings" 508 306 156 40 $cCard $cText
$form.Controls.AddRange(@($btnNow, $btnMile, $btnOpen, $btnSet))

# --- Activity ---
$lblAct  = New-Label 'ACTIVITY' 16 356 200 18 $cMuted $fBodyB
$btnClear = New-Button 'Clear' 588 352 76 26 $cCard $cMuted $fSmall
$log = New-Object System.Windows.Forms.RichTextBox
$log.SetBounds(16, 380, 648, 198)
$log.ReadOnly = $true
$log.BackColor = (C 15 16 17)
$log.ForeColor = $cText
$log.Font = $fMono
$log.BorderStyle = 'None'
$log.HideSelection = $false
$form.Controls.AddRange(@($lblAct, $btnClear, $log))

# --- Footer ---
$footer = New-Panel 0 590 680 30 $cHeader
$lblFoot = New-Label '' 16 7 500 16 $cMuted $fSmall
$lblFootR = New-Label 'STALKER GAMMA Save Backup' 380 7 284 16 $cMuted $fSmall 'TopRight'
$footer.Controls.AddRange(@($lblFoot, $lblFootR))
$form.Controls.Add($footer)

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
function Add-LogLine {
    param($line, $level)
    $color = switch ($level) {
        'ERROR'   { $cRed }   'WARN'  { $cAmber }
        'SUCCESS' { $cAccent } 'DRYRUN' { $cBlue }
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
$script:LogSink = { param($line, $level) Add-LogLine $line $level }

function Set-Status {
    param($text, $color)
    $status.Text = $text; $status.ForeColor = $color; $dot.ForeColor = $color
}

function Update-Info {
    $lblSaveVal.Text  = $script:Config.saveFolderPath
    $lblBakVal.Text   = $script:Config.backupFolderPath
    $exts = ($script:Config.includeExtensions -join '  ')
    $lblWatchVal.Text = "$exts      -      keep newest $($script:Config.keepMaxBackupsPerSave) per save" +
                        $(if ($script:Config.enableZipBackup) { '   (zip)' } else { '' })
    $lblFoot.Text     = "Config: $($script:ConfigPath)"
}
Update-Info

# ---------------------------------------------------------------------------
# Watcher (polls the save folder - responsive and reliable inside a GUI)
# ---------------------------------------------------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.add_Tick({
    if (-not $script:Watching) { return }
    try {
        if (-not (Test-BackupTargetAvailable)) {
            Set-Status 'Waiting for backup drive...' $cAmber
            $lblDrive.Text = 'drive: offline'; $lblDrive.ForeColor = $cAmber
            return
        }
        $lblDrive.Text = 'drive: ready'; $lblDrive.ForeColor = $cAccent
        Set-Status 'Watching - saves are backed up automatically' $cAccent
        $files = @(Get-ChildItem -LiteralPath $script:Config.saveFolderPath -File |
                   Where-Object { $script:Config.includeExtensions -contains $_.Extension.ToLowerInvariant() })
        foreach ($f in $files) { Invoke-BackupForFile -FilePath $f.FullName -StabilityAttempts 1 }
    }
    catch { Write-Log "Watch error: $($_.Exception.Message)" 'ERROR' }
})

function Start-Watch {
    if (-not (Test-BackupTargetAvailable)) {
        Write-Log "Backup drive not available yet - will start saving once it is connected." 'WARN'
    }
    $script:Watching = $true
    $timer.Start()
    $btnToggle.Text = "$symStop   Stop Watching"; $btnToggle.BackColor = $cRed; $btnToggle.ForeColor = $cWhite
    Set-Status 'Watching - saves are backed up automatically' $cAccent
    if ($script:Notify)     { $script:Notify.Text = 'STALKER GAMMA Backup - Watching' }
    if ($script:TrayToggle) { $script:TrayToggle.Text = "$symStop  Stop Watching" }
    Write-Log "Watch mode started." 'INFO'
}
function Stop-Watch {
    $script:Watching = $false
    $timer.Stop()
    $btnToggle.Text = "$symPlay   Start Watching"; $btnToggle.BackColor = $cAccent; $btnToggle.ForeColor = $cBlack
    Set-Status 'Idle' $cMuted
    $lblDrive.Text = ''
    if ($script:Notify)     { $script:Notify.Text = 'STALKER GAMMA Backup - Idle' }
    if ($script:TrayToggle) { $script:TrayToggle.Text = "$symPlay  Start Watching" }
    Write-Log "Watch mode stopped." 'INFO'
}

# ---------------------------------------------------------------------------
# Settings dialog
# ---------------------------------------------------------------------------
function Show-SettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Settings'
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 360)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $cBg; $dlg.Font = $fBody
    if ($form.Icon) { $dlg.Icon = $form.Icon }

    function Add-Field {
        param($label, $y, $value, $browse)
        $l  = New-Label $label 16 ($y + 4) 110 20 $cMuted $fBody
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.SetBounds(132, $y, $(if ($browse) { 330 } else { 412 }), 24)
        $tb.BackColor = $cCard; $tb.ForeColor = $cText; $tb.BorderStyle = 'FixedSingle'
        $tb.Text = [string]$value
        $dlg.Controls.AddRange(@($l, $tb))
        if ($browse) {
            $b = New-Button 'Browse' 470 ($y - 1) 74 25 $cCard $cText $fSmall
            $b.Tag = $tb
            $b.Add_Click($browse)
            $dlg.Controls.Add($b)
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

    $tbSave = Add-Field 'Save folder'      20  $script:Config.saveFolderPath      $pickFolder
    $tbBak  = Add-Field 'Backup folder'    58  $script:Config.backupFolderPath    $pickFolder
    $tbMile = Add-Field 'Milestone folder' 96  $script:Config.milestoneFolderPath $pickFolder
    $tbLog  = Add-Field 'Log file'         134 $script:Config.logFilePath         $pickFile
    $tbExt  = Add-Field 'Extensions'       172 ($script:Config.includeExtensions -join ' ') $null

    $lKeep = New-Label 'Keep backups' 16 214 110 20 $cMuted $fBody
    $numKeep = New-Object System.Windows.Forms.NumericUpDown
    $numKeep.SetBounds(132, 210, 80, 24); $numKeep.Minimum = 1; $numKeep.Maximum = 100000
    $numKeep.BackColor = $cCard; $numKeep.ForeColor = $cText
    $numKeep.Value = [Math]::Min(100000, [Math]::Max(1, [int]$script:Config.keepMaxBackupsPerSave))

    $lDelay = New-Label 'Delay (sec)' 240 214 70 20 $cMuted $fBody
    $numDelay = New-Object System.Windows.Forms.NumericUpDown
    $numDelay.SetBounds(316, 210, 70, 24); $numDelay.Minimum = 0; $numDelay.Maximum = 120
    $numDelay.BackColor = $cCard; $numDelay.ForeColor = $cText
    $numDelay.Value = [Math]::Min(120, [Math]::Max(0, [int]$script:Config.backupDelaySeconds))

    $chkZip = New-Object System.Windows.Forms.CheckBox
    $chkZip.Text = 'Store each backup as a .zip'
    $chkZip.SetBounds(132, 248, 300, 24)
    $chkZip.ForeColor = $cText; $chkZip.BackColor = [System.Drawing.Color]::Transparent
    $chkZip.Checked = [bool]$script:Config.enableZipBackup

    $btnSave   = New-Button 'Save'   300 304 116 32 $cAccent $cBlack
    $btnCancel = New-Button 'Cancel' 428 304 116 32 $cCard   $cText
    $dlg.Controls.AddRange(@($lKeep, $numKeep, $lDelay, $numDelay, $chkZip, $btnSave, $btnCancel))

    $btnCancel.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })
    $btnSave.Add_Click({
        $save = $tbSave.Text.Trim(); $bak = $tbBak.Text.Trim()
        $mile = $tbMile.Text.Trim(); $logp = $tbLog.Text.Trim()
        if (-not $save -or -not $bak -or -not $logp) {
            [System.Windows.Forms.MessageBox]::Show('Save folder, Backup folder and Log file are required.', 'Settings', 'OK', 'Warning') | Out-Null
            return
        }
        $exts = @($tbExt.Text -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object {
            $x = $_.Trim().ToLowerInvariant(); if (-not $x.StartsWith('.')) { $x = ".$x" }; $x })
        if ($exts.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Enter at least one extension, e.g. .scop .scoc', 'Settings', 'OK', 'Warning') | Out-Null
            return
        }
        if (-not $mile) { $mile = Join-Path $bak 'Milestones' }
        $newCfg = [PSCustomObject]@{
            saveFolderPath        = $save
            backupFolderPath      = $bak
            milestoneFolderPath   = $mile
            includeExtensions     = $exts
            backupDelaySeconds    = [double]$numDelay.Value
            keepMaxBackupsPerSave = [int]$numKeep.Value
            enableZipBackup       = [bool]$chkZip.Checked
            logFilePath           = $logp
        }
        try {
            Save-BackupConfig -Config $newCfg -Path $script:ConfigPath
            $script:Config = Import-BackupConfig -ConfigPath $script:ConfigPath
            Update-Info
            Write-Log 'Settings saved.' 'SUCCESS'
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not save settings:`n$($_.Exception.Message)", 'Settings', 'OK', 'Error') | Out-Null
        }
    })

    $dlg.AcceptButton = $btnSave
    $dlg.CancelButton = $btnCancel
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

# ---------------------------------------------------------------------------
# Button actions
# ---------------------------------------------------------------------------
$btnToggle.Add_Click({ if ($script:Watching) { Stop-Watch } else { Start-Watch } })

$btnNow.Add_Click({
    $btnNow.Enabled = $false
    try {
        if (Test-BackupTargetAvailable) { Write-Log 'Manual one-time backup requested.' 'INFO'; Invoke-BackupAll }
        else { Write-Log 'Backup drive not available - connect it first.' 'ERROR' }
    } catch { Write-Log "Backup Now failed: $($_.Exception.Message)" 'ERROR' }
    finally { $btnNow.Enabled = $true }
})

$btnMile.Add_Click({
    $btnMile.Enabled = $false
    try {
        if (Test-BackupTargetAvailable) { Invoke-MilestoneBackup }
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
$btnClear.Add_Click({ $log.Clear() })

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
$script:Notify.Text             = 'STALKER GAMMA Backup - Idle'
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
})

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------
Write-Log "Ready - settings loaded from config." 'INFO'
Write-Log "Click 'Start Watching' to auto-backup every save while you play." 'INFO'
Write-Log "Use 'Take Milestone' for a permanent, never-deleted snapshot." 'INFO'
Write-Log "Change folders any time in Settings. Closing to the X keeps it in the tray." 'INFO'

$script:Form = $form
if (-not $NoShow) {
    [System.Windows.Forms.Application]::Run($form)
}
else {
    Write-Host 'UI constructed successfully (NoShow).'
    try { if ($script:Notify) { $script:Notify.Visible = $false; $script:Notify.Dispose() } } catch { }
}
