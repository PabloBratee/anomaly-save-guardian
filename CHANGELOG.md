# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-06-04

First public release of STALKER GAMMA Save Backup. A polished, dependency-free
Windows PowerShell / .NET WinForms app for automatically backing up and safely
restoring S.T.A.L.K.E.R. Anomaly / GAMMA save files.

No changes to the backup config format are expected from earlier local builds;
your existing `stalker-gamma-backup-config.json` keeps working.

### Added
- **Guided first-run welcome** that explains setup in three steps and reassures
  users their originals are never changed. Appears on first run or when the save
  folder isn't set yet.
- **Clear status area** with five colour-coded states: *Idle*, *Watching*,
  *Waiting for backup drive*, *Backing up*, and *Needs attention* — plus a
  "last backup at HH:mm:ss" reassurance while watching.
- **Guided Restore Backup flow** that lists rolling, milestone and zip restore
  points, previews exactly what will be copied, warns to close the game, creates
  a pre-restore safety backup, and restores the selected save after confirmation.
- **Restore safety checks** for complete `.scop` + `.scoc` pairs, optional
  `.dds` thumbnails, timestamp and `__002` suffix stripping, destination path
  validation, and zip path traversal blocking.
- **Tooltips** on all major controls.
- **Reset to defaults** button in Settings (reloads the example template).
- **Inline validation** in Settings: warns about missing save folder, an offline
  backup drive, or identical save/backup folders, with friendly messages.
- `scripts/check-syntax.ps1` — parse-checks every `.ps1` file.
- `scripts/test-restore.ps1` — fake-save tests for restore discovery,
  pre-restore safety backups, incomplete-pair blocking, zip restore and zip-slip
  protection.
- `scripts/package-release.ps1` — builds a clean release `.zip` containing only
  the files users need (git-ignored `dist/`).
- Community files: `CONTRIBUTING.md`, `SECURITY.md`, issue templates and a pull
  request template.
- Automatic backup engine (`backup-stalker-gamma-saves.ps1`) with watch,
  one-time, milestone and dry-run modes.
- Desktop GUI (`stalker-gamma-backup-ui.ps1`) with a dark theme, live activity
  log, and a double-click launcher.
- **Settings dialog** to change save / backup / milestone / log folders,
  extensions, retention, delay and zip mode without editing JSON.
- **System tray** support: minimise or close (X) to tray, double-click to
  restore, right-click menu, and a true Exit.
- **Milestone snapshots** that are never removed by retention - ideal for
  hardcore / Invictus runs.
- Timestamped, append-only backups (`name__YYYY-MM-DD_HH-mm-ss.ext`); originals
  are only ever read, never modified.
- First-run config seeding from `stalker-gamma-backup-config.example.json`.

### Changed
- **Redesigned main window**: polished header, accent status strip, clearer
  primary/secondary actions, and an Activity log that's easier to scan with an
  empty-state hint.
- **Redesigned Settings dialog**: grouped into *Folders*, *Backup behavior* and
  *Advanced & logging*, with helper text under each field and consistent Browse
  buttons. Explains that milestones are permanent and the zip trade-off.
- Long folder paths now truncate cleanly with the full path in a tooltip, so the
  layout never breaks.
- Settings now clears the in-memory backup cache after a save, so changed paths
  take effect immediately.
- Rolling retention now keeps the latest grouped restore points total instead
  of counting individual files. The default is 10 restore points, `.scop` /
  `.scoc` / optional `.dds` stay together, and milestones plus pre-restore
  safety backups are kept separately.
- Rapid manual backups or milestones that land in the same second now get a
  `__002`-style suffix instead of overwriting an existing backup with the same
  timestamp.
- Expanded README with *Recommended setup*, *Troubleshooting*, *Safety* and
  *Releases* sections; refreshed screenshot.
- `&` now renders literally in labels and headers (no accidental mnemonics).

### Security / Safety
- Restore never deletes live saves or backups, never modifies backup files, and
  refuses to overwrite matching live files unless the pre-restore safety backup
  succeeds first.
- Pre-restore safety backups are stored under
  `PreRestoreSafetyBackups\yyyy-MM-dd_HH-mm-ss_restore_<save-name>` inside the
  configured backup folder and are not part of retention cleanup.

### Notes
- Still 100% built-in PowerShell / .NET — no dependencies.
- Automatic backup still only reads and copies original saves.
- Added safe fake-save release tests for backup copying, retention, milestones,
  config errors, extension filtering, zip mode and guided restore behavior.
- Created by GAM33RSFR33AK.
