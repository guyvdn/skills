---
name: windows-dev-drive
description: 'Use this skill only when the user explicitly asks to set up, audit, or tune a Windows Dev Drive — creating a ReFS/VHDX Dev Drive, marking it trusted, Microsoft Defender performance mode, filter allow lists, or redirecting NuGet/npm/pip/cargo/Gradle/Maven package caches onto it.'
version: 1.0.0
---

# Windows Dev Drive

A Dev Drive is a ReFS volume with developer-specific file system optimisations, a *trusted*
flag, and control over which minifilters attach. On a trusted Dev Drive, Microsoft Defender
runs in **performance mode** — scans are deferred until after the file open completes
(async) instead of blocking it (sync). Microsoft measures large wins on clone, restore and
build; the biggest single factor is that build output and package caches stop being scanned
synchronously.

**Start with the audit.** Most machines already have a Dev Drive that is mis-tuned rather
than missing.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Test-DevDrive.ps1
```

Read-only. Reports prerequisites, machine policy, per-volume trust and attached filters,
Defender performance mode, Defender exclusions that overlap the drive, and which package
caches still live on `C:`. Ends with a numbered list of fixes.

## The four things that actually matter

| # | Setting | Check | Fix |
|---|---|---|---|
| 1 | Volume is ReFS **and trusted** | `fsutil devdrv query D:` | `fsutil devdrv trust D:` |
| 2 | Defender performance mode on | `(Get-MpPreference).PerformanceModeStatus` → `1` | `Set-MpPreference -PerformanceModeStatus Enabled` |
| 3 | Package caches point at the drive | `Test-DevDrive.ps1` | `Set-DevDriveCaches.ps1` |
| 4 | **No** Defender folder exclusions on the drive | `(Get-MpPreference).ExclusionPath` | `Remove-MpPreference -ExclusionPath 'D:\...'` |

Untrusted = synchronous real-time protection = no performance benefit at all. Trust is set
automatically at format time and is **per machine**: move the VHDX elsewhere and it comes
back untrusted.

## Do not add Defender exclusions for a Dev Drive

This is the most common mistake, and it points the opposite way from the
[windows-defender-dev](../windows-defender-dev/) skill:

- A **folder exclusion** blocks scanning altogether — faster, but zero protection.
- **Performance mode** defers the scan — nearly the same speed, and the files still get scanned.

Microsoft's own wording: performance mode "provides significantly better protection than
other performance tuning methods, such as using folder exclusions, which block security
scans altogether." So exclude *tool* paths on `C:` (Visual Studio, MSBuild, `VBCSCompiler.exe`)
via `windows-defender-dev`, and leave the Dev Drive itself to performance mode. An exclusion
covering the whole drive root (`d:`) silently makes performance mode irrelevant.

## Creating a Dev Drive

Existing volumes **cannot** be converted — the Dev Drive designation happens only at format
time, and reformatting destroys the content. Two routes:

**Partition** — faster (no virtual disk layer), less flexible. Do this from Windows Settings:
System → Storage → Advanced storage settings → Disks & volumes → *Create dev drive*, so the
destructive resize/format step is explicit and visible.

**VHDX** — slightly slower, portable and resizable. Scripted:

```powershell
# elevated
powershell -ExecutionPolicy Bypass -File scripts/New-DevDriveVhdx.ps1 `
  -VhdxPath C:\Users\<user>\DevDrives\dev.vhdx -SizeGB 250 -DriveLetter E
```

Creates and attaches the vdisk via `diskpart`, formats with `Format-Volume -DevDrive`, marks
it trusted, and prints next steps. Supports `-WhatIf`, `-Fixed`, `-Filters`, `-RegisterAutoMount`.

Minimum size is 50 GB. Prefer **dynamically expanding VHDX** on a **per-user path**, and keep
it off removable disks (unsupported). BitLocker on the host volume already covers the VHDX —
no need to encrypt the mounted drive separately.

After the first reboot, confirm the drive still mounts. If it does not, re-run with
`-RegisterAutoMount` to add a logon task that calls `Mount-DiskImage`.

Formatting from the command line directly, if you already have an empty volume:

```powershell
Format-Volume -DriveLetter E -DevDrive        # PowerShell
format E: /DevDrv /Q                          # CMD
```

## Redirecting package caches

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Set-DevDriveCaches.ps1 -DriveLetter D -WhatIf
powershell -ExecutionPolicy Bypass -File scripts/Set-DevDriveCaches.ps1 -DriveLetter D -Move

# Subset of caches — an array parameter, so use -Command, not -File
powershell -ExecutionPolicy Bypass -Command "& './scripts/Set-DevDriveCaches.ps1' -DriveLetter D -Caches NuGet,Npm -Move"
```

> **`-File` cannot pass arrays.** `-File ... -Caches NuGet,Npm` fails validation (one literal
> string `NuGet,Npm`) and `-Caches NuGet Npm` used to bind `Npm` to the next positional
> parameter. All three scripts set `PositionalBinding = $false`, so a stray argument now errors
> instead of landing somewhere unexpected — but multi-value arguments still need `-Command`.

Idempotent, supports `-WhatIf`. Defaults to **User** scope and a per-user root
`D:\packages\<username>` (Microsoft's ACL recommendation for multi-user devices); `-Scope Machine`
is the `setx /M` equivalent and needs elevation. `-Move` relocates existing content with
`robocopy /MOVE` — close Visual Studio, IDEs and build agents first.

| Tool | Variable | Old default |
|---|---|---|
| NuGet (dotnet, MSBuild, VS) | `NUGET_PACKAGES` | `%USERPROFILE%\.nuget\packages` |
| npm | `npm_config_cache` | `%AppData%\npm-cache` |
| pip | `PIP_CACHE_DIR` | `%LocalAppData%\pip\Cache` |
| Cargo | `CARGO_HOME` | `%USERPROFILE%\.cargo` |
| vcpkg | `VCPKG_DEFAULT_BINARY_CACHE` | `%LOCALAPPDATA%\vcpkg\archives` |
| Gradle | `GRADLE_USER_HOME` | `%USERPROFILE%\.gradle` |
| Maven | `MAVEN_OPTS` (`-Dmaven.repo.local=`) | `%USERPROFILE%\.m2\repository` |

Environment variable changes need a restart of open consoles, IDEs and Visual Studio — often
a reboot in practice.

### NuGet: prefer NuGet.config over the env var for repo-scoped work

`NUGET_PACKAGES` **overrides** `globalPackagesFolder` in every `NuGet.config`, including
repository-specific settings. For a single repo, set `globalPackagesFolder` in the config
instead; use the env var only for a machine-wide default.

```powershell
dotnet nuget locals global-packages --list   # verify the effective path
```

Known issue: `dotnet tool` does not respect the NuGet packages path
([dotnet/sdk#15306](https://github.com/dotnet/sdk/issues/15306)).

## What belongs on the drive — and what does not

**Yes:** source repos, package caches, build output and intermediates. Point VS build output
at the Dev Drive too (Project properties → *Base output path*).

**No:** the tools themselves. Visual Studio, MSBuild, the .NET SDK and the Windows SDK belong
on `C:` — those locations carry security and isolation guarantees a Dev Drive folder does not,
and binaries there would be scanned asynchronously. Microsoft explicitly does not recommend
installing applications on a Dev Drive.

**Maybe:** `%TEMP%` / `%TMP%`. Real gains, but many programs use them, and Windows Update needs
the `WinSetupMon` filter to be allowed if TEMP lives on a Dev Drive.

**Not useful:** WSL project files. WSL runs in its own VHD and is outside the Windows file
system, so accessing Dev Drive files from a distro gains nothing. ReFS also does not support
WSL's `metadata` mount option, so Linux permissions on Windows-hosted files need NTFS.

## Filters

Filter Manager turns **all** minifilters off on a Dev Drive except antivirus-altitude ones
(`FSFilter Anti-Virus`, altitude 320000–329999). Anything else must be allow-listed, or the
feature depending on it breaks silently.

```powershell
fsutil devdrv query                                       # machine policy + allow list
fsutil devdrv query D:                                    # trust + currently attached filters
fsutil devdrv setfiltersallowed "WdFilter, PrjFlt"        # REPLACES the list, machine-wide
fltmc filters                                             # actual filter names on this machine
```

| Need | Filter |
|---|---|
| Windows Defender | `WdFilter` (attached by default) |
| Defender for Endpoint EDR sensor | `MsSecFlt` |
| GVFS sparse enlistments, VS Live Unit Testing (ProjFS) | `PrjFlt` |
| Docker containers out of the Dev Drive | `bindFlt`, `wcifs` |
| Resource Monitor file names, WPR file system ops | `FileInfo` |
| Process Monitor | `ProcMon24` (version-dependent — confirm with `fltmc filters`) |
| TEMP redirected to the Dev Drive (Windows Update) | `WinSetupMon` |
| WDAC managed installer tracking | `applockerfltr` |

To discover what a scenario needs: temporarily mark the drive untrusted, run the scenario,
note which filters attached, re-trust, then allow-list them and remove one at a time.

`fsutil devdrv enable /disallowAv` detaches antivirus entirely from **all** Dev Drives. Don't —
performance mode already gets most of the speed with the scans intact. `/allowAv` restores it.

## Enterprise / managed machines

Dev Drive is switched off by default on devices whose Windows updates are policy-managed
(temporary enterprise feature control). Group Policy: Computer Configuration → Administrative
Templates → System → Filesystem → **Enable dev drive**, plus *Let antivirus filter protect Dev
Drives* and **Dev Drive filter attach policy**. Backing registry values under
`HKLM:\System\CurrentControlSet\Policies`: `FsEnableDevDrive`, `FltmgrDevDriveAllowAntivirusFilter`,
`FltmgrDevDriveAttachPolicy`. `fsutil devdrv query` shows which lines come from group policy.

Performance mode can also be forced centrally: Intune OMA-URI
`./Device/Vendor/MSFT/Defender/Configuration/PerformanceModeStatus` (`0` = enable, default;
`1` = disable), or Group Policy *Configure performance mode status* under Microsoft Defender
Antivirus → Real-time Protection (24H2+ templates only).

## Gotchas

- **`PerformanceModeStatus` is read one way and configured the other.** In PowerShell,
  `(Get-MpPreference).PerformanceModeStatus` is **`1` = Enabled, `0` = Disabled** — verified by
  setting each value and reading it back. The Intune CSP
  `./Device/Vendor/MSFT/Defender/Configuration/PerformanceModeStatus` uses the **opposite**
  map (`0` = enable, default; `1` = disable). Don't carry the CSP numbers over to
  `Get-MpPreference` output. Cross-check against Windows Security → Virus & threat protection
  → Manage settings → Dev Drive protection → *See volumes*, which lists each volume's real state.
- **Tamper protection can swallow `Set-MpPreference` silently** — no error, value unchanged.
  Always read the value back after setting it (`(Get-MpPreference).PerformanceModeStatus`)
  rather than trusting that the cmdlet succeeded.
- Performance mode needs Defender as the **primary** AV with real-time protection **on**, platform
  `4.18.2303.8`+ and intelligence `1.385.1455.0`+. Third-party AV gets no performance mode —
  only filter allow-list tuning.
- Performance mode does nothing for high `MsMpEng.exe` CPU. Use the Defender
  [Performance Analyzer](https://learn.microsoft.com/defender-endpoint/tune-performance-defender-antivirus)
  for that, or the [windows-perf](../windows-perf/) skill.
- Trust and filter policy are stored **per machine**. A VHDX copied to another machine mounts
  as an ordinary volume and must be re-designated.
- ReFS uses slightly more RAM than NTFS — 8 GB minimum, 16 GB recommended.
- Block cloning (Windows 11 24H2+ / Server 2025) makes file copies on the drive near-free
  metadata operations. Nothing to configure; check cluster size with
  `fsutil fsinfo refsinfo D:` (4 KB default is right for source trees).
- Unsupported: `C:`, removable/hot-pluggable disks, dynamic disks (use Storage Spaces),
  converting a volume in place.
- Deleting a VHDX Dev Drive takes two steps: delete the volume in Settings, then **Detach VHD**
  in Disk Management before the `.vhdx` file can be removed.
- Lost track of a Dev Drive VHDX: `diskpart` → `list vdisk`, or
  `Get-Disk | Select-Object FriendlyName, Location`.

## Reference

- [Set up a Dev Drive on Windows 11](https://learn.microsoft.com/en-us/windows/dev-drive/)
- [Protect Dev Drive using performance mode](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-endpoint-antivirus-performance-mode)
- [Configure Dev Drive security policy for enterprise devices](https://learn.microsoft.com/en-us/windows/dev-drive/group-policy)
- [Dev Drive for Performance Improvements in Visual Studio and Dev Boxes](https://aka.ms/vsdevdrive)
