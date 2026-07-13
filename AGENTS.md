# Anomaly Save Guardian — Agent Guide

Shared operating guide for Codex, Claude Code, and other agents. `CLAUDE.md` points here; keep this file canonical. The detailed `README.md` remains the long-form source of truth.

## Product purpose

- Small, **dependency-free Windows** utility that auto-backs-up S.T.A.L.K.E.R. Anomaly / GAMMA save files: it watches the save folder and copies every new/changed save as it appears, and offers guided restore.
- Owner/users: Pablo (as GAM33RSFR33AK) and end users. Current release line: **v1.0.0**.
- Non-goals: no external dependencies, package managers, or services — built entirely on built-in PowerShell / .NET.

## Sources of truth

Current user request → the `.ps1` scripts → `scripts/` tests and `.github/workflows/ci.yml` → `README.md`, `CHANGELOG.md`, `SECURITY.md` → recent Git history.

## Stack and shape

- Windows PowerShell 5.1 (built in) or PowerShell 7+; Windows Forms / .NET for the UI and tray. **Preserve Windows PowerShell 5.1 compatibility** unless explicitly changed.
- Key files (repo root):
  - `backup-stalker-gamma-saves.ps1` — watch/backup engine.
  - `restore-stalker-gamma-saves.ps1` — guided restore.
  - `stalker-gamma-backup-ui.ps1` — WinForms UI + tray.
  - `Start-Anomaly-Save-Guardian.vbs` / `Launch-Anomaly-Save-Guardian.cmd` — no-console launchers.
  - `stalker-gamma-backup-config.example.json` — template; `stalker-gamma-backup-config.json` is the **personal, machine-specific config** and is gitignored (never commit or read its paths into output).
  - `scripts/` — `check-syntax.ps1`, `test-restore.ps1`, `test-release.ps1`, `test-ui-single-instance.ps1`, `package-release.ps1`.

## Commands (PowerShell)

- Syntax gate (this is CI): `.\scripts\check-syntax.ps1`
- Restore tests: `.\scripts\test-restore.ps1`
- Release/single-instance tests: `.\scripts\test-release.ps1`, `.\scripts\test-ui-single-instance.ps1`
- Package a release: `.\scripts\package-release.ps1`

CI (`.github/workflows/ci.yml`, windows-latest) parses all scripts via `check-syntax.ps1` on push/PR.

## Architecture and high-risk safety rules

- **Logical save** = `.scop` + `.scoc` (+ optional `.dds` thumbnail) grouped and backed up together as one restore point.
- Three backup classes with **separate retention**: rolling (newest per save name, scoped to the rolling folder), milestones (latest 5 by default, scoped to the milestone folder), and pre-restore safety backups. Retention for one class must never touch another.
- **Original live saves must never be deleted by retention.** The only files retention deletes are old restore points inside the configured backup folders. Pre-restore safety backups are never deleted by retention.
- **Restore must create a pre-restore safety backup before overwriting** matching live save files, and confirm with the user.
- **Zip extraction must block path traversal** (reject entries resolving outside the target). Zip mode stores each complete save as one `.zip`.
- Must tolerate locked/partly-written saves and an unplugged backup drive without crashing.

## Security and privacy

- No secrets in this project. Never commit or print the personal config, real save-folder paths, logs (`*.log`, `backup-log.txt`), `Milestones/`, save files (`*.scop/.scoc/.dds/.sav`), or `dist/` release artifacts — all gitignored.

## Testing

- Tests must use **temporary fixture folders**, never Pablo's real save or backup folders. Remove fixtures after running.

## Definition of done

Scoped diff; `.\scripts\check-syntax.ps1` passes and relevant `scripts/test-*.ps1` run (or honestly reported if skipped); PowerShell 5.1 compatibility preserved; retention/restore/zip safety invariants intact; no personal paths, saves, or artifacts committed; accurate Git status.
