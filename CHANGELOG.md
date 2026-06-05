# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-06-04

### Refreshed v1.0.0 package
- **Milestone snapshots now back up only the newest complete logical save** from
  the live savedgames folder instead of every save in the folder.
- Milestones use the same logical-save grouping as rolling backups:
  `.scop` + `.scoc` are required, and optional `.dds` thumbnails are included
  when present.
- If the newest live save group is incomplete because the game is still writing,
  milestone waits briefly and re-scans; if it remains incomplete, milestone uses
  the newest complete group instead.
- **Milestone retention now keeps the latest 5 milestone restore points by
  default** and deletes older milestone restore points only inside the configured
  milestone folder.
- **Default retention changed to 5** for rolling backups and milestones. Existing
  configs without the new `keepMaxMilestones` key keep working and use `5`.
- Zip mode now applies to milestones the same way it applies to rolling backups:
  one complete logical save group per `.zip`.
- Milestone filenames now use minute precision (`yyyy-MM-dd_HH-mm`), with a
  shared `__002` collision suffix when needed.
- UI copy now more clearly explains that rolling backups replace by save name,
  milestones use the newest complete save, and zip mode stores one complete
  save group per `.zip`.
- **UI/UX polish:** the main window now shows the backup rules as three readable
  pills (rolling / milestones / zip) instead of one long line that could clip,
  and the Settings dialog has more breathing room with clearer, properly-spaced
  helper text.
- **Removed the confusing Settle delay setting** from the Settings dialog. The
  app now uses a fixed, built-in **5-second** settle delay so a save's files
  finish writing before they are copied. Older configs that still contain a
  `backupDelaySeconds` value keep loading; the value is ignored and normalized to
  5 seconds.
- Version, tag and release remain `v1.0.0`; the package remains
  `Anomaly-Save-Guardian-v1.0.0.zip`.

First public release of Anomaly Save Guardian. A polished, dependency-free
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
- Desktop GUI (`stalker-gamma-backup-ui.ps1`) with a dark theme and live activity
  log, branded **Anomaly Save Guardian** in the title bar, header and tray.
- **No-console launcher** (`Start-Anomaly-Save-Guardian.vbs`) for normal use:
  starts the app with no PowerShell console window left open. The
  `Launch-Anomaly-Save-Guardian.cmd` launcher remains as a troubleshooting
  fallback.
- **App icon** (`anomaly-save-guardian.ico`): a protective shield with a circular
  restore arrow, used by the window, tray and desktop shortcut.
- **Settings dialog** to change save / backup / milestone / log folders,
  extensions, retention and zip mode without editing JSON.
- **System tray** support: minimise or close (X) to tray, double-click to
  restore, right-click menu, and a true Exit.
- **Milestone snapshots** for manually saving a restore point before risky
  moments in hardcore / Invictus runs.
- **Logical save grouping**: `.scop` + `.scoc` are treated as the required save
  pair, with optional `.dds` thumbnails grouped into the same restore point.
- Rolling backups use minute-precision names (`name__YYYY-MM-DD_HH-mm.ext`) and
  always read/copy originals without modifying live saves.
- First-run config seeding from `stalker-gamma-backup-config.example.json`.

### Changed
- **Redesigned main window**: polished header, accent status strip, clearer
  primary/secondary actions, and an Activity log that's easier to scan with an
  empty-state hint.
- **Redesigned Settings dialog**: grouped into *Folders*, *Backup behavior* and
  *Advanced & logging*, with helper text under each field and consistent Browse
  buttons. Explains milestone retention and the zip trade-off.
- Long folder paths now truncate cleanly with the full path in a tooltip, so the
  layout never breaks.
- Settings now clears the in-memory backup cache after a save, so changed paths
  take effect immediately.
- Rolling backups now replace the previous backup for the same logical save name
  instead of accumulating endless timestamped copies of the same quicksave,
  autosave, sleep save, or manual save. The default cap is 5 distinct logical
  saves; milestones and pre-restore safety backups are kept separately.
- Zip mode now stores one complete logical save group per `.zip`, with `.scop`,
  `.scoc` and optional `.dds` together.
- Milestone snapshots that land in the same minute keep `__002`-style collision
  suffixes instead of overwriting an existing milestone.
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
- Automatic backup still only reads and copies original saves; it never deletes
  or modifies live savedgames.
- Added safe fake-save release tests for logical save grouping, rolling
  replacement, retention, milestones, config errors, extension filtering, grouped
  zip mode and guided restore behavior.
- Complete `.scop` + `.scoc` groups are no longer falsely reported as missing a
  pair in restore discovery; `.dds` remains optional.
- Release ZIP: `Anomaly-Save-Guardian-v1.0.0.zip`.
- SHA256: published on the
  [v1.0.0 release page](https://github.com/PabloBratee/anomaly-save-guardian/releases/tag/v1.0.0).
- Created by GAM33RSFR33AK.
