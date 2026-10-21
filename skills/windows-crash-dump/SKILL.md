---
name: windows-crash-dump
description: 'Use this skill only when the user explicitly asks why Windows crashed, bluescreened, rebooted unexpectedly or "just died" — covers reading the bugcheck from the event log without admin, getting an admin-only crash dump out to a readable place, running !analyze -v with cdb from the WinDbg package, and telling a driver crash from a kernel bug, a hardware fault or a plain power loss.'
version: 1.0.0
---

# Why did Windows crash?

**Start with the report.** Read-only, needs no admin:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Get-CrashReport.ps1
```

It lists Kernel-Power 41, bugcheck (WER 1001) and unexpected-shutdown (6008) events, WHEA hardware
errors, the dump files on disk and the updates installed in the same window. `-Days N` widens it.

## Read the events first

| What you see | What it means |
|---|---|
| Kernel-Power 41 **and** WER 1001 with a bugcheck code | A real BSOD. Get the dump and analyze it. |
| Kernel-Power 41 with `BugcheckCode=0`, no 1001 | Not a bugcheck: power loss, a hard hang, or a held power button. A dump will not exist. Look at PSU, thermals, firmware. |
| WHEA-Logger errors near the crash | Hardware reported a fault (CPU machine check, PCIe, memory). Treat that as the lead before any software theory. |
| 6008 "previous system shutdown at HH:MM was unexpected" | The **crash time**. Kernel-Power 41 and 1001 are logged at the *next boot*, minutes later. |

Traps:

- **volmgr 161 "Dump file creation failed"** can appear while WER 1001 says a dump *was* saved, and the
  dump is fine. Check the file before believing 161.
- **User-mode crashes in the Application log just before** (`.NET Runtime 1026`, `Application Error
  1000`) cannot bugcheck the kernel. They are noise unless the dump names that process *and* a driver it uses.
- Filter 1001 by provider: only `Microsoft-Windows-WER-SystemErrorReporting` 1001 is a bugcheck.

## Get the dump out — it is admin-only

`C:\Windows\MEMORY.DMP` and `C:\Windows\Minidump\*.dmp` can be *listed* unelevated (`cmd /c dir`) but
not opened. Copy the newest minidump somewhere readable with one UAC prompt. From an agent session,
hand the user this — bash syntax, so it works as a `!` line:

```bash
powershell.exe -NoProfile -Command "Start-Process cmd -Verb RunAs -Wait -ArgumentList '/c copy C:\Windows\Minidump\<name>.dmp <writable-dir>\crash.dmp'"
```

The copy inherits the target folder's ACL, so the unelevated session can read it. The minidump (a few
MB) is enough for `!analyze -v`; reach for `MEMORY.DMP` only when the minidump lacks the memory you
need, e.g. the user-mode command line of the crashing process.

## Analyze

```powershell
winget install --id Microsoft.WinDbg -e     # once; no admin
powershell -ExecutionPolicy Bypass -File scripts/Get-CrashReport.ps1 -DumpPath <writable-dir>\crash.dmp
```

The WinDbg package ships **`cdb.exe` and `kd.exe`** in `amd64\` under
`(Get-AppxPackage Microsoft.WinDbg).InstallLocation`, and they run directly from there. No Windows SDK
needed. The first run downloads symbols (`%LOCALAPPDATA%\symbols`), which takes a minute or two.

For anything deeper, run cdb yourself:

```powershell
$cdb = Join-Path (Get-AppxPackage Microsoft.WinDbg).InstallLocation 'amd64\cdb.exe'
& $cdb -z crash.dmp -y "srv*$env:LOCALAPPDATA\symbols*https://msdl.microsoft.com/download/symbols" -c "!analyze -v; lm t n; q"
```

## Reading the stack — whose fault is it?

Look past the first few frames: `KeBugCheckEx`, `MiSystemFault`, `MmAccessFault`, `KiPageFault` are
just the crash *machinery*. The frame below them is where it went wrong.

| Stack shows | Verdict |
|---|---|
| A third-party `.sys` (anything not `nt`, `hal`, Microsoft-signed) | That driver. Update or roll it back; `lmvm <name>` gives version and vendor. |
| Only `nt!` / Microsoft modules, called from a user process via a syscall | A Windows bug. Check what update landed just before; report via Feedback Hub with the dump. |
| Random, different modules on every crash, or `MEMORY_MANAGEMENT` / `0x1A` / `0x124` | Hardware: RAM, overclock/XMP, CPU. Not a driver hunt. |
| `IMAGE_NAME` is a driver but the stack is generic memory-manager code | Blame-shifted: corrupted memory was found, not caused, there. Look for repeat patterns. |

`!analyze` often prints `MODULE_NAME: nt` / `FAILURE_BUCKET_ID: AV_nt!MiSystemFault` for any page
fault in kernel mode; that names the crash handler, not the culprit. Read the stack yourself.

A single crash with a clean Windows-only stack and no WHEA errors needs no local fix. Record the stack
so a recurrence can be compared, and act (roll back the update, test RAM) only if it repeats.
