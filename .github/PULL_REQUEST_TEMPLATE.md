## What does this change?

Briefly describe the change and the user-facing effect.

## Why?

What problem does it solve?

## Checklist

- [ ] `.\scripts\check-syntax.ps1` passes (all `.ps1` parse cleanly)
- [ ] `.\scripts\test-release.ps1` passes using temporary fake saves only
- [ ] UI still constructs: `powershell -STA -ExecutionPolicy Bypass -File .\stalker-gamma-backup-ui.ps1 -NoShow`
- [ ] No external dependencies added (built-in PowerShell 5.1 / .NET only)
- [ ] Original saves are still only ever read/copied — never modified, moved, renamed, or deleted
- [ ] Backup logic stays in `backup-stalker-gamma-saves.ps1` (UI doesn't reimplement it)
- [ ] CLI usage of the engine still works
- [ ] `CHANGELOG.md` updated (if user-facing)
- [ ] README updated and screenshot noted as needing a refresh (if the UI changed)
- [ ] New config keys (if any) have backward-compatible defaults and are documented

## How did you test it?

Describe what you ran (dry-run, temp folders, etc.). **Do not test against your real saves.**
