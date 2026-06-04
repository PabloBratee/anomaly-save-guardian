# Security Policy

## Scope & safety model

STALKER GAMMA Save Backup runs locally on your PC using built-in Windows
PowerShell / .NET. It has **no network features**, no telemetry, and no external
dependencies.

By design:

- Your original save files are only ever **read and copied** — never modified,
  moved, renamed, or deleted.
- The only files the tool ever **deletes** are *old backup copies* inside the
  backup folder (retention), and only those matching the names it created.
  Milestone snapshots are never deleted.
- Your personal config (`stalker-gamma-backup-config.json`) stays on your
  machine and is git-ignored.

## Supported versions

The latest release receives fixes. Older versions are not maintained.

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
