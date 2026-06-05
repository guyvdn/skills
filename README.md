# guyvdn/skills

[![skills.sh](https://skills.sh/b/guyvdn/skills?v=1)](https://skills.sh/guyvdn/skills)

A collection of AI agent skills for developer workflows on Windows.

## Install

```bash
npx skills add guyvdn/skills
```

## Skills

| Skill | Description |
|---|---|
| [windows-perf](skills/windows-perf/) | Diagnose CPU spikes, disable telemetry services and unnecessary startup items on Windows |
| [windows-defender-dev](skills/windows-defender-dev/) | Configure Windows Defender path and process exclusions for a Windows developer machine — covers Visual Studio 2022 (v17) and 2026 (v18), Visual Studio Code, JetBrains Rider, .NET SDK, NuGet, MSBuild, SQL Server Management Studio, and user-supplied project folders. Idempotent, safe to re-run. |

## Usage

After installing, ask your AI agent:
- *"My CPU keeps spiking, can you have a look?"*
- *"Set up Windows Defender exclusions for my dev machine (Visual Studio, VS Code, Rider, SSMS)"*
- *"Tune my Windows machine for development"*

## Scripts

Skills include standalone PowerShell scripts (requires admin). Run from the **repo root**:

```powershell
# Service & startup cleanup
powershell -ExecutionPolicy Bypass -File skills/windows-perf/scripts/Disable-UnnecessaryServices.ps1

# Defender exclusions (interactive)
powershell -ExecutionPolicy Bypass -File skills/windows-defender-dev/scripts/Set-DefenderExclusions.ps1

# Defender exclusions (non-interactive)
powershell -ExecutionPolicy Bypass -File skills/windows-defender-dev/scripts/Set-DefenderExclusions.ps1 -ProjectFolders "D:\projects","D:\source"
```
