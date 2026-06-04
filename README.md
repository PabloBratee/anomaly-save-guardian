# STALKER GAMMA Save Backup

A small, dependency-free **Windows** tool that automatically backs up your
**S.T.A.L.K.E.R. GAMMA / Anomaly** save files. It watches your save folder and
copies every new or changed save the moment it appears — so a bad death, a crash,
or a corrupt save never costs you a run.

Built entirely on **built-in PowerShell / .NET** — nothing to install.

![Screenshot of the app](screenshot.png)

> **Safe by design:** your original saves are only ever *read and copied* — never
> modified, renamed, moved, or deleted. The only files the tool ever deletes are
> *old backup copies* in the backup folder (retention), and milestone snapshots
> are never deleted at all.

---

## Features

- 🟢 **Auto-watch** — backs up every save as you play.
- 🏁 **Milestone snapshots** — permanent, never-deleted backups for hardcore /
  Invictus runs.
- 🧰 **In-app Settings** — change folders, extensions, retention, delay and zip
  mode with folder pickers (no JSON editing).
- 🗂️ **Timestamped, append-only** backups — a death can never overwrite an
  older backup.
- ♻️ **Retention** — keep the newest *N* backups per save; old ones pruned safely.
- 🗜️ **Optional `.zip`** backups.
- 📌 **System tray** — minimise/close to tray, keeps running in the background.
- 🛟 **Robust** — handles locked/partly-written saves and an unplugged backup
  drive without ever crashing.

---

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in) — or PowerShell 7+
- A backup destination (a second drive is recommended)

---

## Quick start

1. Get the files into one folder (anywhere) — clone or
   [download the ZIP](https://github.com/PabloBratee/anomaly-save-guardian):
   ```
   git clone https://github.com/PabloBratee/anomaly-save-guardian.git
   ```
   The folder must contain at least:
   - `backup-stalker-gamma-saves.ps1`
   - `stalker-gamma-backup-ui.ps1`
   - `stalker-gamma-backup-config.example.json`
   - `stalker-gamma-backup.ico`
2. Double-click **`stalker-gamma-backup-ui.ps1`** (or create a shortcut — see
   below). On first run it creates `stalker-gamma-backup-config.json` from the
   example.
3. Click **Settings** and point **Save folder** and **Backup folder** at the
   right places, then **Save**.
4. Click **Start Watching** and minimise. Done — every save is now backed up.

> If Windows blocks the script, launch it once with:
> `powershell -ExecutionPolicy Bypass -File .\stalker-gamma-backup-ui.ps1`

### Create a desktop shortcut

Right-click your Desktop → **New → Shortcut**, and use:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "FULL\PATH\TO\stalker-gamma-backup-ui.ps1"
```

Replace `FULL\PATH\TO` with the folder you saved the files in (keep the quotes —
they matter if the path has spaces). Set the icon to `stalker-gamma-backup.ico`
via the shortcut's **Properties → Change Icon**.

---

## Using the app

| Control | What it does |
|---|---|
| **Start / Stop Watching** | Toggles automatic backups (green = idle, red = watching). |
| **Backup Now** | Backs up all current saves once, immediately. |
| **Take Milestone** | Permanent snapshot of all current saves — never auto-deleted. |
| **Open Folder** | Opens the backup folder in Explorer. |
| **Settings** | Change folders, extensions, retention, delay, zip mode. |
| **Clear** | Clears the on-screen activity log. |

**System tray:** the **minimize** button and the **X** both send the window to
the tray (it keeps running and backing up). **Double-click** the tray icon to
reopen it; **right-click** for a quick menu. The only way to fully quit is tray →
**Exit**.

> Make sure the backup drive is connected before watching. If it isn't, the
> status shows *“Waiting for backup drive…”* and resumes automatically once it's
> back.

---

## Configuration

Use **Settings** in the app, or edit `stalker-gamma-backup-config.json` directly:

```json
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
```

| Setting | Meaning |
|---|---|
| `saveFolderPath` | Your GAMMA/Anomaly `appdata\savedgames` folder (source). |
| `backupFolderPath` | Where rolling backups are written. |
| `milestoneFolderPath` | Permanent snapshots — retention **never** deletes these. |
| `includeExtensions` | File types to back up. `.scop` + `.scoc` are a full save; `.dds` is the thumbnail. |
| `backupDelaySeconds` | Settle time after a change before copying. |
| `keepMaxBackupsPerSave` | How many rolling backups to keep per save name. Milestones are exempt. |
| `enableZipBackup` | `true` = store each backup as a `.zip`; `false` = plain copy. |
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
number of deaths and saves. Naming a distinct in-game hard-save also gives it its
own retention bucket.

---

## Restoring a save

1. **Close the game.**
2. Open your backup folder (or the `Milestones` subfolder).
3. Pick the backup you want. A full save is the **`.scop` + `.scoc` pair** with
   the same timestamp — restore **both** (the `.dds` thumbnail is optional). If
   it's a `.zip`, extract it first.
4. Copy the file(s) into your save folder.
5. Remove the `__YYYY-MM-DD_HH-mm-ss` part from each name, e.g.
   `quicksave__2026-06-04_22-30-15.scop` → `quicksave.scop`.
6. Launch the game and load it.

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
(e.g. `quicksave__2026-06-04_22-30-15.scop`).

---

## How it works

- The GUI polls the save folder every ~2 seconds; the CLI `-Watch` uses an
  event-driven `FileSystemWatcher`. Both back up only when a file's
  size + last-write-time actually changes (in-memory de-duplication).
- Before copying, a file must be size-stable and not locked; locked files are
  retried and otherwise skipped (and retried later) — nothing ever crashes the run.
- Retention keeps the newest *N* backups per save name (sorted by the timestamp
  in the filename, which is reliable even though copies share the source's
  modified time). The milestone folder is never scanned by retention.

---

## Project layout

```
backup-stalker-gamma-saves.ps1          # backup engine (also usable as a library)
stalker-gamma-backup-ui.ps1             # the GUI app
stalker-gamma-backup-config.example.json# template (committed)
stalker-gamma-backup-config.json        # your personal config (git-ignored)
stalker-gamma-backup.ico                # app/tray icon
README.md  CHANGELOG.md  LICENSE  .gitignore
```

> Publishing your own copy? Don't run `git init` inside your `savedgames` folder.
> Copy the program files into a separate folder first — the included `.gitignore`
> already excludes saves, your personal config, and logs.

---

## License

[MIT](LICENSE) © 2026 PabloBratee
