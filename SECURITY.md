# Security Policy

## Scope & safety model

Anomaly Save Guardian runs locally on your PC using built-in Windows
PowerShell / .NET. It has **no network features**, no telemetry, and no external
dependencies.

By design:

- Your original save files are only ever **read and copied** — never modified,
  moved, renamed, or deleted during automatic backup.
- Restore is guided and confirmation-based. It writes only into the configured
  save folder, creates a pre-restore safety backup before overwriting matching
  live files, and stops if that safety backup fails.
- Backup files are never modified or deleted during restore. Zip restore points
  are validated and extracted to a temporary folder first so unsafe paths are
  blocked before anything is copied into the live save folder.
- The only files the tool ever **deletes** are old restore points inside their
  configured backup areas. Rolling replacement/retention deletes only old
  rolling restore points inside the configured backup folder. Milestone
  retention deletes only old milestone restore points inside the configured
  milestone folder. Live savedgames, pre-restore safety backups, config files,
  logs and unrelated folders are not deleted by retention.
- Your personal config (`stalker-gamma-backup-config.json`) stays on your
  machine and is git-ignored.

## Supported versions

The latest release receives fixes. Older versions are not maintained.

| Version | Supported |
|---|---|
| v1.0.0 | Yes |

## Reporting a vulnerability

If you find a security issue (for example, a path-handling bug that could cause
the tool to write or delete outside the backup folder):

1. **Do not** open a public issue with exploit details.
2. Use GitHub's **"Report a vulnerability"** (Security → Advisories) on the
   repository, or contact the maintainer privately.
3. Please include: what you observed, steps to reproduce, your Windows /
   PowerShell version, and the relevant config (with personal paths removed).

You'll get an acknowledgement as soon as possible. Thanks for helping keep
fellow stalkers' saves safe.
