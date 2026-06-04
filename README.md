# STALKER GAMMA Save Backup

A small, dependency-free **Windows** app that automatically backs up your
**S.T.A.L.K.E.R. GAMMA / Anomaly** save files. It watches your save folder and
copies every new or changed save the moment it appears — so a bad death, a
crash, or a corrupt save never costs you a run.

Built entirely on **built-in PowerShell / .NET** — nothing to install.

![The STALKER GAMMA Save Backup app, watching and backing up saves](screenshot.png)

> **🛡️ Safe by design:** automatic backups only read and copy your original
> saves. Restores are guided, ask for confirmation, and create a pre-restore
> safety backup before overwriting matching live save files. The only files the
> tool ever deletes are old rolling restore points in the backup folder
> (retention); milestones and pre-restore safety backups are kept separately.

---

## Features

- 🟢 **Auto-watch** — backs up every save the moment it appears as you play.
- 🚦 **Clear status at a glance** — *Idle*, *Watching*, *Waiting for backup
  drive*, *Backing up*, or *Needs attention*, with a colour-coded indicator.
- 🏁 **Milestone snapshots** — permanent, never-deleted backups for hardcore /
  Invictus runs.
- 🧭 **Guided first run** — a friendly welcome walks new users through setup; no
  JSON editing required.
- 🧰 **In-app Settings** — grouped, with folder pickers, helper text, validation
  and a *Reset to defaults* button.
- 🛟 **Restore Backup** — choose a restore point, review the files, create a
  safety backup, then restore with confirmation.
- 🗂️ **Timestamped, append-only** backups — a death can never overwrite an
  older backup.
- ♻️ **Retention** — rolling backups keep the latest 10 restore points by
  default; milestones and pre-restore safety backups are kept separately.
- 🗜️ **Optional `.zip`** backups.
- 📌 **System tray** — minimise/close to tray, keeps running in the background.
- 💪 **Robust** — handles locked/partly-written saves and an unplugged backup
  drive without ever crashing.

---

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in) — or PowerShell 7+
- A backup destination (a **second drive is strongly recommended**)

---

## Quick start

1. **Get the files** into one folder (anywhere):
   - **Easiest:** download the latest release `.zip` from the
     [Releases page](https://github.com/PabloBratee/anomaly-save-guardian/releases)
     and extract it, **or**
   - clone the repo:
     ```
     git clone https://github.com/PabloBratee/anomaly-save-guardian.git
     ```
   The folder must contain at least:
   - `backup-stalker-gamma-saves.ps1`
   - `stalker-gamma-backup-ui.ps1`
   - `Launch STALKER GAMMA Save Backup.cmd`
   - `stalker-gamma-backup-config.example.json`
   - `stalker-gamma-backup.ico`
2. **Run** `Launch STALKER GAMMA Save Backup.cmd` (double-click it), or make a
   shortcut — see below. On first run it creates your personal
   `stalker-gamma-backup-config.json` and shows a short **welcome** that walks
   you through setup.
3. In **Settings**, point **Save folder** and **Backup folder** at the right
   places, then **Save**.
4. Click **Start Watching** and minimise. Done — every save is now backed up.

> If Windows blocks the script, launch it once with:
> ```
> powershell -ExecutionPolicy Bypass -File .\stalker-gamma-backup-ui.ps1
> ```
> See [Troubleshooting](#troubleshooting).

### Launch it like an app

The folder ships with a double-clickable launcher so you don't have to touch
PowerShell or change system execution policy:

- **`Launch STALKER GAMMA Save Backup.cmd`** — just double-click it. It finds
  its own folder, so it works wherever you put the files, and starts the app
  with no console window.

### Create a desktop shortcut

Easiest — run the included helper once from the app folder (double-click it):

```
Create-Desktop-Shortcut.ps1
```

It drops a proper **STALKER GAMMA Save Backup** shortcut on your Desktop, icon
and all, pointing at this folder. (If Windows blocks it, right-click → **Run
with PowerShell**, or use the bypass command in
[Troubleshooting](#troubleshooting).)

Prefer to do it by hand? Right-click your Desktop → **New → Shortcut**, and use:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "FULL\PATH\TO\stalker-gamma-backup-ui.ps1"
```

Replace `FULL\PATH\TO` with the folder you saved the files in (keep the quotes —
they matter if the path has spaces). Set the icon to `stalker-gamma-backup.ico`
via the shortcut's **Properties → Change Icon**.

---

## Recommended setup (GAMMA players)

- **Save folder** — your GAMMA/Anomaly `appdata\savedgames` folder.
  - GAMMA via the launcher: usually `...\GAMMA\Anomaly\appdata\savedgames`.
  - Standalone Anomaly: `...\Anomaly\appdata\savedgames`.
  - Not sure? Make an in-game save, then search your Anomaly folder for a
    `*.scop` file — that folder is your save folder.
- **Backup folder** — put it on a **different physical drive** from the game.
  A backup on the same disk won't help if that disk dies.
- **Keep the defaults** (`.sav .scop .scoc .dds`, keep 10 restore points)
  unless you have a reason to change them. `.scop` + `.scoc` together are a full
  save.
- Before anything risky (a tough fight, the Brain Scorcher, a long-run hardcore
  character), hit **Take Milestone** — it's a permanent snapshot that retention
  never deletes.

---

## Using the app

| Control | What it does |
|---|---|
| **Start / Stop Watching** | Toggles automatic backups (green = idle, red = watching). |
| **Backup Now** | Backs up all current saves once, immediately. |
| **Take Milestone** | Permanent snapshot of all current saves — never auto-deleted. |
| **Restore Backup** | Opens a guided restore flow for rolling, milestone, and safe zip restore points. |
| **Open Folder** | Opens the backup folder in Explorer. |
| **Settings** | Change folders, file types, retention, delay, zip mode. No JSON editing. |
| **Clear** | Clears the on-screen activity log (touches no files). |

Hover any button for a tooltip explaining what it does.

**Status indicator** (top card): tells you exactly what the app is doing —
whether it's actively protecting your saves, idle, waiting for the backup drive,
or needs attention.

**System tray:** the **minimize** button and the **X** both send the window to
the tray (it keeps running and backing up). **Double-click** the tray icon to
reopen it; **right-click** for a quick menu. The only way to fully quit is tray →
**Exit**.

> Make sure the backup drive is connected before watching. If it isn't, the
> status shows *“Waiting for backup drive…”* and resumes automatically once it's
> back.

---

## Configuration

Use **Settings** in the app (recommended), or edit
`stalker-gamma-backup-config.json` directly:

```json
{
  "saveFolderPath": "C:\\Anomaly\\appdata\\savedgames",
  "backupFolderPath": "D:\\STALKER GAMMA Backups",
  "milestoneFolderPath": "D:\\STALKER GAMMA Backups\\Milestones",
  "includeExtensions": [".sav", ".scop", ".scoc", ".dds"],
  "backupDelaySeconds": 3,
  "keepMaxBackupsPerSave": 10,
  "enableZipBackup": false,
  "logFilePath": "D:\\STALKER GAMMA Backups\\backup-log.txt"
}
```

| Setting | Meaning |
|---|---|
| `saveFolderPath` | Your GAMMA/Anomaly `appdata\savedgames` folder (source). |
| `backupFolderPath` | Where rolling backups are written. |
| `milestoneFolderPath` | Permanent snapshots — retention **never** deletes these. Optional; defaults to a `Milestones` subfolder of the backup folder. |
| `includeExtensions` | File types to back up. `.scop` + `.scoc` are a full save; `.dds` is the thumbnail. |
| `backupDelaySeconds` | Settle time after a change before copying. |
| `keepMaxBackupsPerSave` | How many grouped rolling restore points to keep total. The name is kept for backward compatibility. Milestones and pre-restore safety backups are kept separately. |
| `enableZipBackup` | `true` = store each backup as a `.zip`; `false` = plain copy (easiest to restore). |
| `logFilePath` | Where the log is written. |

In raw JSON, Windows paths need **doubled** backslashes (`\\`). The Settings
dialog handles this for you.

---

## Hardcore / Invictus runs: will a death overwrite my backups?

**No.** Each backup is a separate, timestamped file. When you die, the game
overwrites only your *live* save; the tool then writes the dead state as a **new**
backup and leaves every earlier "alive" backup untouched.

To protect a specific point against retention pruning, **Take Milestone** — those
snapshots live in the milestone folder and are never auto-deleted, surviving any
number of deaths and saves.

---

## Restoring a save

Use **Restore Backup** in the main window.

1. **Close the game completely first.**
2. Click **Restore Backup**.
3. Pick a restore point from the list. Newest backups are shown first, with the
   save name, backup time, type, status, and file count.
4. Review exactly what will be copied into your live save folder and which live
   files will be overwritten.
5. Confirm the restore.
6. The app creates a pre-restore safety backup, then copies the selected backup
   files back using the original game save names.
7. Launch the game and load the save.

A full GAMMA/Anomaly save needs the matching **`.scop` + `.scoc` pair** with the
same timestamp. The **`.dds` thumbnail is optional** and is restored when it is
available. If the required pair is missing, the app marks the restore point as
**Missing pair** and blocks restore by default.

### Pre-restore safety backups

Before overwriting any matching live save file, the app copies the current live
file into:

```
<backup folder>\PreRestoreSafetyBackups\yyyy-MM-dd_HH-mm-ss_restore_<save-name>
```

It also writes a small `restore-manifest.txt`. If the safety backup cannot be
created, restore is cancelled before anything is copied into the live save
folder. Safety backups are not touched by retention cleanup.

### Zip restore

If zip backups exist, **Restore Backup** shows them as `Zip` restore points. Zip
files are checked first, extracted to a temporary folder, and only then copied
into the live save folder. Zip entries with folders, `..`, unexpected names, or
unexpected extensions are blocked to prevent path traversal.

Restoring does **not** modify or delete backup files — they stay exactly where
they are.

---

## Command-line usage (optional)

The engine works without the GUI:

```powershell
.\backup-stalker-gamma-saves.ps1 -BackupNow            # one-time backup
.\backup-stalker-gamma-saves.ps1 -Watch                # watch continuously (Ctrl+C to stop)
.\backup-stalker-gamma-saves.ps1 -Milestone            # permanent snapshot
.\backup-stalker-gamma-saves.ps1 -BackupNow -DryRun    # preview, touches nothing
.\backup-stalker-gamma-saves.ps1 -Watch -DryRun        # preview events live
```

Backups are named `OriginalSaveName__YYYY-MM-DD_HH-mm-ss.ext`
(e.g. `quicksave__2026-06-04_22-30-15.scop`). If you create two backups with
the same timestamp, the later one gets a suffix such as
`quicksave__2026-06-04_22-30-15__002.scop` instead of overwriting the first.

---

## How it works

- The GUI polls the save folder every ~2 seconds; the CLI `-Watch` uses an
  event-driven `FileSystemWatcher`. Both back up only when a file's
  size + last-write-time actually changes (in-memory de-duplication).
- Before copying, a file must be size-stable and not locked; locked files are
  retried and otherwise skipped (and retried later) — nothing ever crashes the
  run.
- Retention keeps the newest *N* grouped rolling restore points total, sorted by
  the timestamp in the filename. A `.scop` + `.scoc` pair, plus optional `.dds`
  thumbnail, counts as one restore point; zip backups are grouped the same way.
  Milestone and pre-restore safety backup folders are never scanned by rolling
  retention.

---

## Troubleshooting

**“…cannot be loaded because running scripts is disabled” / Windows blocks it.**
Windows' execution policy is stopping the script. Launch it once with a bypass
for that single run (this does not change your system policy):
```
powershell -NoProfile -ExecutionPolicy Bypass -File .\stalker-gamma-backup-ui.ps1
```
The desktop-shortcut command above does this for you automatically.

**The app “closed” but is still running.** That's intended — the **X** and the
minimize button send it to the **system tray**, so it keeps backing up.
Double-click the tray icon to reopen it, or right-click → **Exit** to quit fully.

**Status says “Waiting for backup drive”.** The drive holding your backup folder
isn't connected. Plug it in — watching resumes and backs up automatically. You
don't need to restart the app.

**“Save folder not found” when I click Start Watching.** Your **Save folder**
isn't set correctly. Open **Settings** and point it at your Anomaly/GAMMA
`appdata\savedgames` folder. Tip: make an in-game save, then search your Anomaly
folder for a `*.scop` file — that folder is the one you want.

**No backups are appearing.**
- Are you **Watching** (button is red / status is green “Watching”)?
- Is the **backup drive connected** (status not “Waiting for backup drive”)?
- Do your saves match the **file types** in Settings (`.scop .scoc` etc.)?
- Check the **Activity log** in the app, or the log file, for errors.
- Try **Backup Now** for an immediate one-off pass.

**I need to load an old save.** Click **Restore Backup** in the app, or see
[Restoring a save](#restoring-a-save) above. Always close the game first. The
app blocks incomplete `.scop` / `.scoc` pairs and creates a safety backup before
overwriting matching live files.

**Restore Backup says “Missing pair”.** That backup is missing either the
`.scop` or `.scoc` file for the selected timestamp. Pick another restore point,
or check whether the matching file is in a different folder.

**Restore failed before copying.** Check that the save folder and backup folder
still exist, and that the backup drive is connected. If the pre-restore safety
backup cannot be created, the restore is cancelled before live files are
overwritten.

**A zip restore was blocked.** The zip did not look like a backup created by the
app, or it contained an unsafe entry. Use a normal restore point or inspect the
backup manually before trying again.

**My save and backup folders are the same / on the same disk.** Use two
*different* folders, ideally on two *different* drives. The Settings dialog warns
you if they're identical, and a backup on the same physical disk won't survive
that disk failing.

---

## Safety

This tool is built to be trustworthy with your saves:

- **Backups are read-only during restore.** Restore reads backup files and copies
  them into the live save folder. Backup files are never modified or deleted.
- **Live files are protected before overwrite.** Restore first creates a
  pre-restore safety backup of matching live files. If that fails, restore stops.
- **Deletions are scoped and conservative.** Retention only deletes old rolling
  restore points it created, and only those physically inside the backup folder.
  Milestone snapshots and pre-restore safety backups are never deleted by
  rolling retention.
- **No network, no telemetry, no dependencies.** Everything runs locally with
  built-in Windows components.
- **Your personal config and logs stay local** and are git-ignored.

See [SECURITY.md](SECURITY.md) for the full safety model and how to report
issues.

---

## Releases

Want to publish or grab a clean download?

- **For users:** download the latest `.zip` from the
  [Releases page](https://github.com/PabloBratee/anomaly-save-guardian/releases),
  extract it anywhere, and follow [Quick start](#quick-start).
- **For maintainers:** build a clean release package (only the files users need —
  never your personal config, logs, or backups):
  ```powershell
  .\scripts\package-release.ps1
  ```
  This creates `dist\STALKER-GAMMA-Save-Backup-vX.Y.Z.zip` and prints the exact
  steps to tag and publish a GitHub Release. The `dist\` folder is git-ignored.
  For the full v1.1.0 checklist, see
  [docs/release-checklist.md](docs/release-checklist.md).

---

## Project layout

```
backup-stalker-gamma-saves.ps1          # backup engine + CLI (also a library)
restore-stalker-gamma-saves.ps1         # restore discovery, validation and copy helpers
stalker-gamma-backup-ui.ps1             # the GUI app
Launch STALKER GAMMA Save Backup.cmd    # double-click launcher
Create-Desktop-Shortcut.ps1             # desktop shortcut helper
stalker-gamma-backup-config.example.json# template (committed)
stalker-gamma-backup-config.json        # your personal config (git-ignored)
stalker-gamma-backup.ico                # app/tray icon
scripts/check-syntax.ps1                # parse-check all .ps1 files
scripts/test-release.ps1                # safe fake-save release tests
scripts/test-restore.ps1                # safe fake-save restore tests
scripts/package-release.ps1             # build a clean release .zip
docs/release-checklist.md               # maintainer release checklist
README.md  CHANGELOG.md  LICENSE  SECURITY.md  CONTRIBUTING.md  .gitignore
```

> Publishing your own copy? Don't run `git init` inside your `savedgames` folder.
> Copy the program files into a separate folder first — the included `.gitignore`
> already excludes saves, your personal config, and logs.

---

## Contributing

Issues and PRs are welcome. Please keep the tool simple, dependency-free, and
safe. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 PabloBratee
