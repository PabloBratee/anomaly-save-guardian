# Release Checklist / Record

The first public release, `v1.0.0`, has already been published.

- Release: `Anomaly Save Guardian v1.0.0`
- Tag: `v1.0.0`
- Release commit: `2727f2d9bc5cf917fbf7f4c18cd4b569d072ab54`
- Release page:
  `https://github.com/PabloBratee/anomaly-save-guardian/releases/tag/v1.0.0`
- Release ZIP: `Anomaly-Save-Guardian-v1.0.0.zip`
- SHA256:
  `603435B7144C8866C36F2C9C8E370CFB9C3B8750BCB4FA7F6BDE2DD14F3BADD8`

> **v1.0.0 refresh:** the release was refreshed in place (still tag `v1.0.0`) to
> apply the **Anomaly Save Guardian** branding, the no-console
> `Start-Anomaly-Save-Guardian.vbs` launcher, the new app icon and the
> `Anomaly-Save-Guardian-v1.0.0.zip` package name. The tag was not moved or
> recreated; only the release asset and notes were updated.

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
