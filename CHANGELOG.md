# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org/).

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
