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
| [windows-perf](skills/windows-perf/) | Diagnose CPU load honestly (kernel vs user vs DPC, simultaneous sampling), work out why a laptop fan never stops, and disable telemetry services and unnecessary startup items on Windows |
| [windows-defender-dev](skills/windows-defender-dev/) | Configure Windows Defender path and process exclusions for a Windows developer machine — covers Visual Studio 2022 (v17) and 2026 (v18), VS Code, JetBrains Rider, .NET SDK, NuGet, MSBuild, SSMS, and user-supplied project folders. Idempotent, safe to re-run. |
| [windows-dev-drive](skills/windows-dev-drive/) | Set up, audit and tune a Windows Dev Drive — ReFS/VHDX creation, trust, Microsoft Defender performance mode, filter allow lists, and redirecting NuGet/npm/pip/cargo/Gradle/Maven package caches onto it. |
| [windows-display-dimming](skills/windows-display-dimming/) | Diagnose and stop a laptop screen dimming by itself — ambient-light adaptive brightness, content-adaptive dimming (Intel DPST / AMD Vari-Bright / CABC), battery-saver dimming, plus a boot task so the fix survives Windows feature updates. |
| [agent-browser-cleanup](skills/agent-browser-cleanup/) | Get `agent-browser` launching again when every command dies with "Chrome exited early (exit code: 0)", and remove the Chrome trees it leaks (hundreds of processes, gigabytes of RAM) — covers the elevated-shell cause that reinstalls and Defender exclusions cannot fix, why `close --all` misses the leak, and why "parent is dead" is the wrong orphan test. |
| [reveal-md](skills/reveal-md/) | Create, run, and export reveal-md presentations. Use when the user wants to create a new slide deck, serve a presentation locally, or export one to PDF. |
| [interactive-reveal-deck](skills/interactive-reveal-deck/) | Build a presentation as a reveal.js deck with a designed interface and interactive demo panels instead of static bullets — per-part accent colours, a chapter rail, a jump-to-slide palette, an annotation layer, and widgets the presenter drives from the clicker. Ships the theme, the code-window tokenizer (C#, JSON, TS), six widget patterns, a scaffold script and a layout verifier. |
| [claude-code-sessions](skills/claude-code-sessions/) | Identify the Claude Code sessions running on this machine — map each one's friendly name to its session id, working directory and pid. Covers why the name is the address and the id usually is not, and why a live pid alone is not a live session. |

## Usage

After installing, ask your AI agent:
- *"My CPU keeps spiking, can you have a look?"*
- *"My fan never stops but Task Manager shows nothing using CPU"*
- *"These CPU numbers don't add up"*
- *"Set up Windows Defender exclusions for my dev machine (Visual Studio, VS Code, Rider, SSMS)"*
- *"Tune my Windows machine for development"*
- *"Audit my Dev Drive setup"*
- *"Set up a Dev Drive and move my NuGet cache onto it"*
- *"My screen keeps dimming on its own, can you turn that off?"*
- *"Disable dynamic/adaptive brightness on my laptop"*
- *"Something left hundreds of chrome.exe processes running"*
- *"agent-browser said it closed everything but the browsers are still there"*
- *"agent-browser can't launch Chrome — it says Chrome exited early without writing DevToolsActivePort"*
- *"Create a reveal-md presentation about microservices"*
- *"Serve my slides.md locally"*
- *"Export my presentation to PDF"*
- *"Make me an interactive reveal.js deck about X"*
- *"This deck is too static — can you make it look designed?"*
- *"Turn my slides.md into a proper reveal.js presentation"*
- *"Add a live demo panel to this slide"*
- *"Check my deck fits on the projector before I present"*
- *"Which Claude session am I in?"*
- *"What other Claude sessions are running?"*
- *"Tell the session in D:\projects\foo what I just changed"*
- *"What is the session id for this window?"*

## Scripts

Skills include standalone PowerShell scripts (requires admin). Run from the **repo root**:

```powershell
# Service & startup cleanup (leaves IIS alone by default)
powershell -ExecutionPolicy Bypass -File skills/windows-perf/scripts/Disable-UnnecessaryServices.ps1

# ...and also disable IIS, if you know you don't host on local IIS
powershell -ExecutionPolicy Bypass -File skills/windows-perf/scripts/Disable-UnnecessaryServices.ps1 -IncludeIIS

# Orphaned agent-browser cleanup (no admin needed; -DryRun to preview)
powershell -ExecutionPolicy Bypass -File skills/agent-browser-cleanup/scripts/Remove-OrphanedAgentBrowsers.ps1 -DryRun

# Chrome on a fixed CDP port for `agent-browser --cdp 9222` (no admin needed; -Stop to shut down)
powershell -ExecutionPolicy Bypass -File skills/agent-browser-cleanup/scripts/Start-AgentBrowserCdp.ps1

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

# List the Claude Code sessions running on this machine (read-only, no admin)
powershell -ExecutionPolicy Bypass -File skills/claude-code-sessions/scripts/Get-ClaudeSessions.ps1

# Scaffold an interactive reveal.js deck (no admin needed)
powershell -ExecutionPolicy Bypass -File skills/interactive-reveal-deck/scripts/New-RevealDeck.ps1 -Path D:\talks\my-talk\deck -Title "My Talk"

# ...with your own parts, which set the per-part accent colours
powershell -ExecutionPolicy Bypass -Command "& './skills/interactive-reveal-deck/scripts/New-RevealDeck.ps1' -Path D:\talks\my-talk\deck -Title 'Kafka for .NET devs' -Parts 'intro:Intro','ingest:Ingest','stream:Streaming','ops:Operations'"

# Check every slide fits the frame and raises no JS errors (needs agent-browser)
powershell -ExecutionPolicy Bypass -File skills/interactive-reveal-deck/scripts/Test-DeckLayout.ps1 -Path D:\talks\my-talk\deck

# ...as JSON, for a script or an agent to consume
powershell -ExecutionPolicy Bypass -File skills/claude-code-sessions/scripts/Get-ClaudeSessions.ps1 -Json
```
