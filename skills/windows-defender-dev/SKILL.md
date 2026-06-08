---
name: windows-defender-dev
description: 'Use this skill only when the user explicitly asks to configure Windows Defender exclusions for a developer machine — covers Visual Studio 2022 (v17) and 2026 (v18), VS Code, JetBrains Rider, .NET SDK, NuGet, MSBuild, SSMS, and user-supplied project folders. Idempotent, safe to re-run.'
version: 1.0.0
---

# Windows Defender Exclusions for Developers

Configure Windows Defender to stop scanning build output, compiler processes, and IDE caches — the main cause of slow builds and IntelliSense lag on Windows.

## Step 1 — Ask for project folders

Before applying, ask the user:
> "What are the paths to your project/source folders? (e.g. D:\source, D:\projects)"

## Step 2 — Run the script

Requires admin PowerShell. Interactive (prompts for folders):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Set-DefenderExclusions.ps1
```

Or pass folders directly (non-interactive):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Set-DefenderExclusions.ps1 -ProjectFolders "D:\projects","D:\source"
```

The script is idempotent — safe to re-run, skips already-present exclusions.

## Step 3 — Verify

```powershell
$p = Get-MpPreference
$p.ExclusionPath
$p.ExclusionProcess
```

## What the script adds

### Path exclusions

| Path | Notes |
|---|---|
| User-supplied project folders | Provided interactively |
| `C:\Program Files\Microsoft Visual Studio` | Covers VS 2022 (v17, `\2022\`) and VS 2026 (v18, `\2026\`) |
| `C:\Program Files (x86)\Microsoft Visual Studio` | VS 2019 and earlier (x86 installer host) |
| `C:\Program Files\Microsoft VS Code` | VS Code system-wide install |
| `%LOCALAPPDATA%\Programs\Microsoft VS Code` | VS Code per-user install |
| `%USERPROFILE%\.vscode\extensions` | VS Code extensions — most-scanned VS Code path |
| `%APPDATA%\Code` | VS Code user data, settings, and language server caches |
| `C:\Program Files\dotnet`, `C:\Program Files (x86)\dotnet` | .NET SDK |
| `C:\Program Files\Microsoft SDKs`, `C:\Program Files (x86)\Microsoft SDKs` | Windows/Azure SDKs |
| `C:\Program Files\Microsoft SQL Server`, `C:\Program Files (x86)\Microsoft SQL Server` | SQL Server tooling |
| `C:\Program Files (x86)\Microsoft SQL Server Management Studio 18` | SSMS 18 — 32-bit installer, lives in `(x86)` |
| `C:\Program Files\Microsoft SQL Server Management Studio 19/20/21` | SSMS 19+ — 64-bit, lives in `Program Files` |
| `C:\Program Files\JetBrains` | Full Rider install |
| `%LOCALAPPDATA%\JetBrains` | Rider per-version caches |
| `%APPDATA%\JetBrains` | Rider settings |
| `%USERPROFILE%\.nuget`, `%LOCALAPPDATA%\NuGet`, `%APPDATA%\NuGet` | NuGet package caches |
| `%USERPROFILE%\.dotnet`, `%LOCALAPPDATA%\Microsoft\dotnet` | .NET SDK user cache |
| `%USERPROFILE%\.librarymanager` | LibMan (client-side library manager) |
| `%LOCALAPPDATA%\Temp\VS`, `%LOCALAPPDATA%\Temp\VSFeedbackIntelliCodeLogs` | VS temp files |
| `%LOCALAPPDATA%\GitCredentialManager`, `%LOCALAPPDATA%\GitHubVisualStudio` | Git credential helpers |
| `%LOCALAPPDATA%\Microsoft\VisualStudio`, `%LOCALAPPDATA%\Microsoft\VisualStudio Services` | VS IDE state |
| `%LOCALAPPDATA%\Microsoft\VSApplicationInsights`, `%LOCALAPPDATA%\Microsoft\VSCommon` | VS telemetry/common |
| `%APPDATA%\Microsoft\VisualStudio`, `%APPDATA%\Visual Studio Setup`, `%APPDATA%\vstelemetry` | VS roaming state |
| `C:\ProgramData\Microsoft\VisualStudio`, `C:\ProgramData\Microsoft Visual Studio` | VS machine-wide state |
| `C:\ProgramData\Microsoft\NetFramework` | .NET Framework machine cache |
| `C:\Windows\Microsoft.NET`, `C:\Windows\assembly` | .NET runtime |

### Process exclusions

| Process | Notes |
|---|---|
| `devenv.exe` | Visual Studio IDE |
| `MSBuild.exe` | Build engine |
| `VBCSCompiler.exe` | Roslyn compiler server — biggest build-time impact |
| `ServiceHub.Host.dotnet.x64.exe` | VS 2022 v17.4+ / v18 ServiceHub host |
| `ServiceHub.RoslynCodeAnalysisService.exe` | IntelliSense / code analysis |
| `ServiceHub.Host.CLR.x86.exe` | VS 2022 v17.3 and earlier |
| `ServiceHub.SettingsHost.exe` | VS settings |
| `ServiceHub.IdentityHost.exe` | VS identity |
| `ServiceHub.VSDetouredHost.exe` | VS detoured host |
| `Microsoft.ServiceHub.Controller.exe` | ServiceHub controller |
| `vstest.console.exe` | Test runner |
| `testhost.exe` | Test host |
| `PerfWatson2.exe` | VS performance watcher |
| `sqlwriter.exe` | SQL Server VSS writer |
| `Code.exe` | Visual Studio Code |
| `Ssms.exe` | SQL Server Management Studio |

## Gotchas

- Requires an **elevated (admin) PowerShell** session.
- Visual Studio 2022 (v17) installs under `\2022\` and Visual Studio 2026 (v18) installs under `\2026\` — both are covered by excluding the parent path `C:\Program Files\Microsoft Visual Studio`.
- All JetBrains Rider per-version folders (`Rider2024.1`, `Rider2024.2`, etc.) are covered by excluding the parent `%LOCALAPPDATA%\JetBrains`.
- `VBCSCompiler.exe` is the single biggest win — it stays resident between builds and Defender hammers it on every recompile.
