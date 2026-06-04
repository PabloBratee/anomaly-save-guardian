# Release Checklist

Use this checklist to publish `v1.1.0`.

## Pre-release

- Confirm `CHANGELOG.md` has the final `1.1.0` notes.
- Confirm `backup-stalker-gamma-saves.ps1` reports `$script:AppVersion = '1.1.0'`.
- Run syntax and release tests:
  ```powershell
  .\scripts\check-syntax.ps1
  .\scripts\test-release.ps1
  ```
- Build the package:
  ```powershell
  .\scripts\package-release.ps1
  ```
- Inspect `dist\STALKER-GAMMA-Save-Backup-v1.1.0.zip` before uploading.

## Publish

After the final release-readiness changes are merged to `main`, run this from an
updated `main` checkout:

```powershell
git switch main
git pull --ff-only origin main
git status
git tag v1.1.0
git push origin main
git push origin v1.1.0
```

Then create a GitHub Release:

- Tag: `v1.1.0`
- Title: `v1.1.0`
- Notes: paste the `CHANGELOG.md` section for `1.1.0`
- Asset: `dist\STALKER-GAMMA-Save-Backup-v1.1.0.zip`

Do not attach personal config, logs, temp folders, or any real save files.
