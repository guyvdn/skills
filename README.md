# guyvdn/skills

[![skills.sh](https://skills.sh/b/guyvdn/skills?v=3)](https://skills.sh/guyvdn/skills)

A collection of AI agent skills for developer workflows on Windows.

## Install

```bash
npx skills add guyvdn/skills
```

## Skills

| Skill | Description |
|---|---|
| [windows-perf](skills/windows-perf/) | Diagnose CPU spikes, disable telemetry services and unnecessary startup items on Windows |
| [windows-defender-dev](skills/windows-defender-dev/) | Configure Windows Defender path and process exclusions for a Windows developer machine — covers Visual Studio 2022 (v17) and 2026 (v18), VS Code, JetBrains Rider, .NET SDK, NuGet, MSBuild, SSMS, and user-supplied project folders. Idempotent, safe to re-run. |
| [windows-dev-drive](skills/windows-dev-drive/) | Set up, audit and tune a Windows Dev Drive — ReFS/VHDX creation, trust, Microsoft Defender performance mode, filter allow lists, and redirecting NuGet/npm/pip/cargo/Gradle/Maven package caches onto it. |
| [windows-display-dimming](skills/windows-display-dimming/) | Diagnose and stop a laptop screen dimming by itself — ambient-light adaptive brightness, content-adaptive dimming (Intel DPST / AMD Vari-Bright / CABC), battery-saver dimming, plus a boot task so the fix survives Windows feature updates. |
| [reveal-md](skills/reveal-md/) | Create, run, and export reveal-md presentations. Use when the user wants to create a new slide deck, serve a presentation locally, or export one to PDF. |

## Usage

After installing, ask your AI agent:
- *"My CPU keeps spiking, can you have a look?"*
- *"Set up Windows Defender exclusions for my dev machine (Visual Studio, VS Code, Rider, SSMS)"*
- *"Tune my Windows machine for development"*
- *"Audit my Dev Drive setup"*
- *"Set up a Dev Drive and move my NuGet cache onto it"*
- *"My screen keeps dimming on its own, can you turn that off?"*
- *"Disable dynamic/adaptive brightness on my laptop"*
- *"Create a reveal-md presentation about microservices"*
- *"Serve my slides.md locally"*
- *"Export my presentation to PDF"*

## Scripts

Skills include standalone PowerShell scripts (requires admin). Run from the **repo root**:

```powershell
# Service & startup cleanup
powershell -ExecutionPolicy Bypass -File skills/windows-perf/scripts/Disable-UnnecessaryServices.ps1

# Dev Drive audit (read-only)
powershell -ExecutionPolicy Bypass -File skills/windows-dev-drive/scripts/Test-DevDrive.ps1

# Redirect package caches onto a Dev Drive
powershell -ExecutionPolicy Bypass -File skills/windows-dev-drive/scripts/Set-DevDriveCaches.ps1 -DriveLetter D -Move

# Defender exclusions (interactive)
powershell -ExecutionPolicy Bypass -File skills/windows-defender-dev/scripts/Set-DefenderExclusions.ps1

# Defender exclusions (non-interactive)
# Multi-value parameters need -Command, not -File: with -File a quoted comma list
# binds as ONE string (quotes included).
powershell -ExecutionPolicy Bypass -Command "& './skills/windows-defender-dev/scripts/Set-DefenderExclusions.ps1' -ProjectFolders 'D:\projects','D:\source'"

# Display auto-dimming audit (read-only)
powershell -ExecutionPolicy Bypass -File skills/windows-display-dimming/scripts/Test-DisplayDimming.ps1

# Turn off auto-dimming now, and keep it off across feature updates
powershell -ExecutionPolicy Bypass -File skills/windows-display-dimming/scripts/Disable-AdaptiveDimming.ps1 -RestartAdapter -InstallTask
```
