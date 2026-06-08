# guyvdn/skills

[![skills.sh](https://skills.sh/b/guyvdn/skills?v=2)](https://skills.sh/guyvdn/skills)

A collection of Claude Code slash commands for developer workflows on Windows.

## Install

```bash
npx skills add guyvdn/skills
```

This installs the commands to `~/.claude/commands/` so they're available in every project.

## Commands

| Command | Description |
|---|---|
| `/windows-perf` | Diagnose CPU spikes, disable telemetry services and unnecessary startup items on Windows |
| `/windows-defender-dev` | Configure Windows Defender path and process exclusions for a Windows developer machine — covers Visual Studio 2022 (v17) and 2026 (v18), VS Code, JetBrains Rider, .NET SDK, NuGet, MSBuild, SSMS, and user-supplied project folders |

## Usage

After installing, use the slash commands in Claude Code:

```
/windows-perf
/windows-defender-dev
```

Or ask your AI agent:
- *"My CPU keeps spiking, can you have a look?"* → `/windows-perf`
- *"Set up Windows Defender exclusions for my dev machine"* → `/windows-defender-dev`

## Standalone Scripts

The PowerShell scripts can also be run directly without AI assistance (requires admin). Run from the **repo root**:

```powershell
# Service & startup cleanup
powershell -ExecutionPolicy Bypass -File scripts/Disable-UnnecessaryServices.ps1

# Defender exclusions (interactive)
powershell -ExecutionPolicy Bypass -File scripts/Set-DefenderExclusions.ps1

# Defender exclusions (non-interactive)
powershell -ExecutionPolicy Bypass -File scripts/Set-DefenderExclusions.ps1 -ProjectFolders "D:\projects","D:\source"
```
