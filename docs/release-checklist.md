# Release Checklist / Record

The first public release, `v1.0.0`, has already been published.

- Release: `Anomaly Save Guardian v1.0.0`
- Tag: `v1.0.0`
- Release commit: `2727f2d9bc5cf917fbf7f4c18cd4b569d072ab54`
- Release page:
  `https://github.com/PabloBratee/anomaly-save-guardian/releases/tag/v1.0.0`
- Release ZIP: `Anomaly-Save-Guardian-v1.0.0.zip`
- SHA256: recompute from `dist\Anomaly-Save-Guardian-v1.0.0.zip` before any
  release asset refresh.

> **v1.0.0 refresh:** any refresh should stay on tag `v1.0.0`, keep the
> `Anomaly-Save-Guardian-v1.0.0.zip` package name, and avoid moving, deleting or
> recreating the tag. Refresh only the existing release asset/notes after review.
> The current refresh keeps the public version at `v1.0.0`; do not create a
> `v1.0.1` or `v1.1.0` release for this change.

Do not recreate the tag or create a new release unless intentionally preparing a
new version.

## v1.0.0 validation

- `CHANGELOG.md` has the final `1.0.0` notes.
- `backup-stalker-gamma-saves.ps1` reports `$script:AppVersion = '1.0.0'`.
- Syntax and release tests:
  ```powershell
  .\scripts\check-syntax.ps1
  .\scripts\test-ui-single-instance.ps1
  .\scripts\test-release.ps1
  .\scripts\test-restore.ps1
  powershell -STA -NoProfile -ExecutionPolicy Bypass -File .\stalker-gamma-backup-ui.ps1 -NoShow
  ```
- Release package build command:
  ```powershell
  .\scripts\package-release.ps1
  ```
- `dist\Anomaly-Save-Guardian-v1.0.0.zip` was inspected before upload.
- The zip contains `restore-stalker-gamma-saves.ps1`,
  `Start-Anomaly-Save-Guardian.vbs` and `anomaly-save-guardian.ico`, and does not
  contain personal config, logs, temp folders, `.git`, `.github`, tests or a
  nested `dist` folder.

## v1.0.0 logical save refresh checks

- One logical save is `.scop` + `.scoc`, plus optional `.dds`.
- Zip mode stores one complete logical save group per zip.
- Rolling backups replace the previous backup for the same save name and use
  minute-precision names (`yyyy-MM-dd_HH-mm`).
- Normal/default retention is `5`.
- Rolling replacement only deletes older normal rolling backups in the configured
  backup folder.
- Live savedgames are never deleted or modified by backup/replacement.
- Milestone backs up only the newest complete logical save from the live
  savedgames folder.
- If the newest live group is incomplete, milestone waits briefly and re-scans;
  if it is still incomplete, milestone uses the newest complete group.
- Milestones keep the latest `5` restore points by default.
- Old milestone backups are deleted only inside the configured milestone folder
  according to milestone retention.
- Milestones, rolling backups and pre-restore safety backups are kept separate:
  milestone retention never deletes live savedgames, normal rolling backups or
  pre-restore safety backups.

## v1.0.0 package verification

- Package path remains `dist\Anomaly-Save-Guardian-v1.0.0.zip`.
- The zip includes:
  - `Start-Anomaly-Save-Guardian.vbs`
  - `Launch-Anomaly-Save-Guardian.cmd`
  - `stalker-gamma-backup-ui.ps1`
  - `backup-stalker-gamma-saves.ps1`
  - `restore-stalker-gamma-saves.ps1`
  - `Create-Desktop-Shortcut.ps1`
  - `stalker-gamma-backup-config.example.json`
  - `anomaly-save-guardian.ico`
  - `README.md`
  - `CHANGELOG.md`
  - `SECURITY.md`
  - `LICENSE`
- The zip excludes `.git`, `.github`, tests, scripts, docs, personal config,
  logs, temp folders, nested `dist`, old zip names and scratch files.
- Extract to a clean temp folder and run:
  ```powershell
  powershell -STA -NoProfile -ExecutionPolicy Bypass -File .\stalker-gamma-backup-ui.ps1 -NoShow
  ```
- Compute SHA256 and update the existing `v1.0.0` release notes and asset only.
