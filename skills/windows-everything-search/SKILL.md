---
name: windows-everything-search
description: 'Use this skill only when the user explicitly asks why voidtools Everything (the file search app) has become slow, laggy, unresponsive or memory-hungry, or asks to tune, slim down or set up its index on a developer PC — covers Match Path, excluding node_modules/.git/bin/obj and package caches, subst drives indexed twice, and editing Everything.ini without losing the change.'
version: 1.0.0
---

# Everything (voidtools) search lag

Everything is fast because it searches **file names** in an in-memory index. On a developer
PC it slows down for two reasons that compound each other: the index fills up with millions
of build and dependency files, and **Match Path** makes every keystroke scan the full path
of every one of them. The process doesn't hang (no Application Hang events). It is busy: each
search fans out over every core, and the CPU-seconds pile up.

Measured on one machine (2026-10-21): a 3.2 M-entry ReFS Dev Drive had **2.3 M entries
under `node_modules`/`.git`/`bin`/`obj`**, and a further ~0.9 M in package caches redirected
onto it. The fix took the database from 232 MB to 102 MB and memory from 548 MB to 250 MB,
and typing was instant again.

## Audit first

Read-only, no admin:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Test-EverythingIndex.ps1
pwsh -File scripts/Test-EverythingIndex.ps1 -CountEntries   # + per-volume counts, ~20 s per million files
```

It reports client CPU-seconds per minute and memory, database size, Match Path / Regex,
missing exclusions, package caches still indexed, and volumes indexed twice.

## Apply

Confirm with the user first: excluded folders **disappear from Everything's results** (and
`*\bin` also hides folders such as `C:\Program Files\Git\bin`). Offer `-SkipFilter`.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Set-EverythingTuning.ps1 -WhatIf
powershell -ExecutionPolicy Bypass -File scripts/Set-EverythingTuning.ps1
powershell -ExecutionPolicy Bypass -File scripts/Set-EverythingTuning.ps1 -SkipFilter "*\bin,*\obj" -ExtraExclude "D:\Temp"
```

`-File` hands a PowerShell list (`'a','b'`) over as **one string**, quotes included, so pass
lists comma-separated in a single string. It splits on commas only when every piece starts
with `*` or a drive letter, so `"C:\Data\Smith, John"` stays one folder. Run it
**unelevated**, as the user whose Everything it is. It refuses when elevated; pass
`-AllowElevated` if UAC is off or you are the built-in Administrator. It covers
Everything **1.4** only, and refuses 1.5 (`Everything64.exe`, `Everything-1.5a.ini`).

It closes the client, backs up `Everything.ini` beside itself (`.bak-<timestamp>`), and then:

| Change | Why |
|---|---|
| `match_path=0` | Name-only search uses the fast path. Typing a `\` still matches the full path (`match_path_when_search_contains_path_separator=1`, the default). `Ctrl+U` toggles it for one search. |
| Exclude `*\node_modules`, `*\.git`, `*\bin`, `*\obj`, `*\$RECYCLE.BIN` | Folder-name filters, matched on every volume. This is most of the bloat. |
| Exclude every package cache found | NuGet, npm, pnpm (including stray `<drive>:\.pnpm-store`), pip, uv, vcpkg, Maven, Gradle — resolved from the same variables the `windows-dev-drive` skill sets. Merged with any existing entries. |
| Stop indexing a subst drive covered by its parent | It shares the volume GUID and is indexed and journal-monitored twice. Only when the whole-volume entry has **no include-only** list and both GUIDs are present. Otherwise the subst may be the only thing indexing those files, and it is left alone. |

After that it restarts Everything, waits for the rebuild CPU to settle, exits once more so the
database is saved, reports the size before and after, and starts Everything again. If the size
barely moved, the filters didn't take: check **Tools ▸ Options ▸ Exclude**.

The changes are worked out a second time after Everything exits, because exiting rewrites
the ini. The ini is written to a temp file and then swapped in. If anything throws once
Everything is closed, a `finally` block starts it again.

The script is idempotent: a second run prints `Nothing to change.`

## Traps (each one bit during the first fix)

- **Edits made while Everything runs are lost.** It rewrites the whole ini on exit. Close it with
  `Everything.exe -exit` first. That closes the client only; the `Everything` *service*
  (session 0) stays up and that's fine.
- **Which ini?** `Everything.ini` next to the exe is usually a stub containing `app_data=1`,
  which moves the real one to `%APPDATA%\Everything\Everything.ini`. The database is
  `%LOCALAPPDATA%\Everything\Everything.db` unless `db_location` is set.
- **Backslashes are doubled inside quoted values**: Everything writes `C:\foo` as
  `"C:\\foo"` (see `ntfs_volume_roots`). Write exclusions the same way. The doubled form is
  what was verified to work.
- **Don't use Git Bash `sed -i` on the ini.** It silently converted CRLF to LF. The scripts read
  and write through .NET and keep CRLF and any BOM.
- **Disable a redundant volume, don't remove it.** With `auto_include_fixed_volumes=1` and
  `scan_volume_drive_letters=1` Everything rediscovers drive letters, so the script sets
  `ntfs_volume_includes`/`_monitors` to `0` for that entry instead of deleting it.
- **Database size is the proof.** The window title shows only the search text, and the db is
  written on exit. So: exit, measure `Everything.db`, restart.
- **A db last saved days ago** means Everything hasn't exited cleanly since (a crash or a forced
  shutdown). It rescans on the next start. That's harmless, but expect a slow first minute.

Folder indexes (`folders=`) are rescanned on a timer instead of journal-monitored. That wasn't
the cause here. Only look at them if the audit lists any.
