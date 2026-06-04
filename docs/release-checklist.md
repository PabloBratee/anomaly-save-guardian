# Release Checklist / Record

The first public release, `v1.0.0`, has already been published.

- Release: `Anomaly Save Guardian v1.0.0`
- Tag: `v1.0.0`
- Release commit: `2727f2d9bc5cf917fbf7f4c18cd4b569d072ab54`
- Release page:
  `https://github.com/PabloBratee/anomaly-save-guardian/releases/tag/v1.0.0`
- Release ZIP: `STALKER-GAMMA-Save-Backup-v1.0.0.zip`
- SHA256:
  `BB41AAB5214CBE7DD8F7CD1E3251B82ECD7A1B4DE1F023C0A43F1E2655BC8E6C`

Do not recreate the tag, republish the release, or replace the release asset
unless intentionally preparing a new release.

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
- `dist\STALKER-GAMMA-Save-Backup-v1.0.0.zip` was inspected before upload.
- The zip contains `restore-stalker-gamma-saves.ps1` and does not
  contain personal config, logs, temp folders, `.git`, `.github`, tests or a
  nested `dist` folder.
