# Contributing

Thanks for your interest in improving **STALKER GAMMA Save Backup**! This is a
small, dependency-free tool and the goal is to keep it that way: simple,
portable, and safe for non-technical players.

## Guiding principles

- **Safe by design.** Original save files are only ever *read and copied* —
  never modified, moved, renamed, or deleted. Any change that could touch a
  user's real saves will not be accepted.
- **No dependencies.** Built-in Windows PowerShell 5.1 / .NET only. No Node,
  Python, Electron, NuGet, or external modules.
- **Beginner-friendly.** Most users are players, not developers. Wording should
  be plain and reassuring.
- **Backup logic stays in `backup-stalker-gamma-saves.ps1`.** The UI
  (`stalker-gamma-backup-ui.ps1`) should not reimplement copying/retention.

## Project layout

| File | Purpose |
|---|---|
| `backup-stalker-gamma-saves.ps1` | Backup engine + CLI (also dot-sourced as a library by the UI). |
| `restore-stalker-gamma-saves.ps1` | Restore discovery, validation, safety backup and copy helpers. |
| `stalker-gamma-backup-ui.ps1` | The WinForms desktop app. |
| `Launch STALKER GAMMA Save Backup.cmd` | Portable double-click launcher. |
| `Create-Desktop-Shortcut.ps1` | Desktop shortcut helper. |
| `stalker-gamma-backup-config.example.json` | Config template (committed). |
| `scripts/check-syntax.ps1` | Parse-checks every `.ps1`. Run before pushing. |
| `scripts/test-release.ps1` | Runs safe temp-folder fake-save backup/release tests. |
| `scripts/test-restore.ps1` | Runs safe temp-folder fake-save restore tests. |
| `scripts/package-release.ps1` | Builds a clean release `.zip`. |

## Before you open a PR

1. **Parse-check** all scripts:
   ```powershell
   .\scripts\check-syntax.ps1
   ```
2. **Run the safe fake-save release tests**:
   ```powershell
   .\scripts\test-release.ps1
   .\scripts\test-restore.ps1
   ```
3. **Run the single-instance guard test**:
   ```powershell
   .\scripts\test-ui-single-instance.ps1
   ```
4. **Build the UI** without showing it (sanity check that it constructs):
   ```powershell
   powershell -STA -NoProfile -ExecutionPolicy Bypass -File .\stalker-gamma-backup-ui.ps1 -NoShow
   ```
5. **Test the engine safely** against throwaway folders with `-DryRun` and/or a
   temporary fake save folder — never your real saves.
6. Keep **PowerShell 5.1 compatibility** (don't rely on PS7-only syntax).
7. Avoid risky Unicode glyphs in source; build them by char code as the existing
   code does (e.g. `[char]0x25B6`).
8. If you change the UI, refresh `screenshot.png` with neutral/sample paths.
9. If you add a config key, give it a **backward-compatible default** in
   `Import-BackupConfig` and document it in the README.

## Commit / PR style

- Small, focused commits with clear messages.
- Describe the user-facing effect, not just the code change.
- Update `CHANGELOG.md` under an `Unreleased` heading for anything users notice.

Thanks, stalker. 🟢
