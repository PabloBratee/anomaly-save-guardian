# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-06-04

A UX and public-readiness release. No changes to the save/backup behaviour or
config format — your existing `stalker-gamma-backup-config.json` keeps working.

### Added
- **Guided first-run welcome** that explains setup in three steps and reassures
  users their originals are never changed. Appears on first run or when the save
  folder isn't set yet.
- **Clear status area** with five colour-coded states: *Idle*, *Watching*,
  *Waiting for backup drive*, *Backing up*, and *Needs attention* — plus a
  "last backup at HH:mm:ss" reassurance while watching.
- **In-app "How to Restore" guide** with step-by-step instructions and an
  *Open backup folder* shortcut.
- **Tooltips** on all major controls.
- **Reset to defaults** button in Settings (reloads the example template).
- **Inline validation** in Settings: warns about missing save folder, an offline
  backup drive, or identical save/backup folders, with friendly messages.
- `scripts/check-syntax.ps1` — parse-checks every `.ps1` file.
- `scripts/package-release.ps1` — builds a clean release `.zip` containing only
  the files users need (git-ignored `dist/`).
- Community files: `CONTRIBUTING.md`, `SECURITY.md`, issue templates and a pull
  request template.

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
- Expanded README with *Recommended setup*, *Troubleshooting*, *Safety* and
  *Releases* sections; refreshed screenshot.
- `&` now renders literally in labels and headers (no accidental mnemonics).

### Notes
- Still 100% built-in PowerShell / .NET — no dependencies.
- Original saves are still only ever read and copied — never modified, moved,
  renamed, or deleted.

## [1.0.0] - 2026-06-04

### Added
- Automatic backup engine (`backup-stalker-gamma-saves.ps1`) with watch,
  one-time, milestone and dry-run modes.
- Desktop GUI (`stalker-gamma-backup-ui.ps1`) with a dark theme, live activity
  log, and a desktop shortcut launcher.
- **Settings dialog** to change save / backup / milestone / log folders,
  extensions, retention, delay and zip mode without editing JSON.
- **System tray** support: minimise or close (X) to tray, double-click to
  restore, right-click menu, and a true Exit.
- **Milestone snapshots** that are never removed by retention - ideal for
  hardcore / Invictus runs.
- Timestamped, append-only backups (`name__YYYY-MM-DD_HH-mm-ss.ext`); originals
  are only ever read, never modified.
- Per-save retention, optional `.zip` backups, robust handling of locked files
  and an unavailable backup drive.
- First-run config seeding from `stalker-gamma-backup-config.example.json`.
