---
description: Configure Windows Defender path and process exclusions for a Windows developer machine — covers Visual Studio 2022 (v17) and 2026 (v18), VS Code, JetBrains Rider, .NET SDK, NuGet, MSBuild, SSMS, and user-supplied project folders
---

# Windows Defender Exclusions for Developers

Configure Windows Defender to stop scanning build output, compiler processes, and IDE caches — the main cause of slow builds and IntelliSense lag on Windows.

## Step 1 — Ask for project folders

Before applying, ask the user:
> "What are the paths to your project/source folders? (e.g. D:\source, D:\projects)"

## Step 2 — Run the script

Ask the user to save the script below as `Set-DefenderExclusions.ps1` and run it from an **admin PowerShell** prompt.

Interactive (prompts for folders):
```powershell
powershell -ExecutionPolicy Bypass -File .\Set-DefenderExclusions.ps1
```

Or pass folders directly (non-interactive):
```powershell
powershell -ExecutionPolicy Bypass -File .\Set-DefenderExclusions.ps1 -ProjectFolders "D:\projects","D:\source"
```

The script is idempotent — safe to re-run, skips already-present exclusions.

### Script

```powershell
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Adds Windows Defender exclusions for a Visual Studio / VS Code / JetBrains / SSMS developer machine.

.DESCRIPTION
    Idempotent — safe to run multiple times. Skips exclusions already present.
    Path comparison is case-insensitive to match Windows filesystem behaviour.
    Covers: Visual Studio 2022 (v17) and 2026 (v18), VS Code, .NET SDK, NuGet, MSBuild,
    JetBrains Rider, SQL Server Management Studio, and one or more user-supplied project folders.

.PARAMETER ProjectFolders
    One or more paths to your source/project folders (e.g. D:\projects, D:\source).
    If omitted, the script will prompt interactively.

.EXAMPLE
    .\Set-DefenderExclusions.ps1 -ProjectFolders "D:\projects","D:\source"
#>
param(
    [string[]]$ProjectFolders
)

$userPath = $env:USERPROFILE

$pathExclusions = @(
    # .NET / Windows runtimes
    'C:\Windows\Microsoft.NET',
    'C:\Windows\assembly',

    # User profile – dotnet, NuGet, VS
    "$userPath\.dotnet",
    "$userPath\.librarymanager",
    "$userPath\.nuget",
    "$userPath\AppData\Local\Microsoft\VisualStudio",
    "$userPath\AppData\Local\Microsoft\VisualStudio Services",
    "$userPath\AppData\Local\GitCredentialManager",
    "$userPath\AppData\Local\GitHubVisualStudio",
    "$userPath\AppData\Local\Microsoft\dotnet",
    "$userPath\AppData\Local\Microsoft\VSApplicationInsights",
    "$userPath\AppData\Local\Microsoft\VSCommon",
    "$userPath\AppData\Local\Temp\VS",
    "$userPath\AppData\Local\Temp\VSFeedbackIntelliCodeLogs",
    "$userPath\AppData\Local\NuGet",
    "$userPath\AppData\Roaming\Microsoft\VisualStudio",
    "$userPath\AppData\Roaming\NuGet",
    "$userPath\AppData\Roaming\Visual Studio Setup",
    "$userPath\AppData\Roaming\vstelemetry",

    # JetBrains
    "$userPath\AppData\Local\JetBrains",
    "$userPath\AppData\Roaming\JetBrains",
    'C:\Program Files\JetBrains',

    # ProgramData
    'C:\ProgramData\Microsoft\VisualStudio',
    'C:\ProgramData\Microsoft\NetFramework',
    'C:\ProgramData\Microsoft Visual Studio',

    # Program Files (x64) — parent path covers VS 2022 (\2022\) and VS 2026 (\2026\)
    'C:\Program Files\Microsoft Visual Studio',
    'C:\Program Files\Microsoft VS Code',
    'C:\Program Files\dotnet',
    'C:\Program Files\Microsoft SDKs',
    'C:\Program Files\Microsoft SQL Server',

    # Program Files (x86) — VS 2019 and earlier used an x86 installer host
    'C:\Program Files (x86)\Microsoft Visual Studio',
    'C:\Program Files (x86)\dotnet',
    'C:\Program Files (x86)\Microsoft SDKs',
    'C:\Program Files (x86)\Microsoft SQL Server',

    # VS Code user install and data
    "$userPath\AppData\Local\Programs\Microsoft VS Code",
    "$userPath\.vscode\extensions",
    "$userPath\AppData\Roaming\Code",

    # SSMS — 18 uses (x86), 19+ use Program Files (x64)
    'C:\Program Files (x86)\Microsoft SQL Server Management Studio 18',
    'C:\Program Files\Microsoft SQL Server Management Studio 19',
    'C:\Program Files\Microsoft SQL Server Management Studio 20',
    'C:\Program Files\Microsoft SQL Server Management Studio 21'
)

$processExclusions = @(
    # Visual Studio core
    'devenv.exe',
    'MSBuild.exe',
    'VBCSCompiler.exe',

    # ServiceHub – VS 2022 v17 and earlier
    'ServiceHub.SettingsHost.exe',
    'ServiceHub.IdentityHost.exe',
    'ServiceHub.VSDetouredHost.exe',
    'ServiceHub.Host.CLR.x86.exe',
    'Microsoft.ServiceHub.Controller.exe',

    # ServiceHub – VS 2022 v17.4+ / v18
    'ServiceHub.Host.dotnet.x64.exe',
    'ServiceHub.RoslynCodeAnalysisService.exe',

    # Testing
    'vstest.console.exe',
    'testhost.exe',

    # Misc
    'PerfWatson2.exe',
    'sqlwriter.exe',

    # VS Code
    'Code.exe',

    # SQL Server Management Studio
    'Ssms.exe'
)

# --- Collect project folders ---
if (-not $ProjectFolders) {
    Write-Host ""
    Write-Host "Enter your project/source folder(s), one per line."
    Write-Host "Leave blank and press Enter when done."
    Write-Host ""
    $folders = @()
    while ($true) {
        $folderInput = Read-Host "  Project folder"
        if ([string]::IsNullOrWhiteSpace($folderInput)) { break }
        if (-not (Test-Path $folderInput)) {
            Write-Host "  warning: path does not exist yet - adding anyway: $folderInput" -ForegroundColor Yellow
        }
        $folders += $folderInput
    }
    $ProjectFolders = $folders
    if ($ProjectFolders.Count -eq 0) {
        Write-Host "  note: no project folders specified - only standard VS/JetBrains paths will be added." -ForegroundColor Yellow
    }
} else {
    foreach ($folder in $ProjectFolders) {
        if (-not (Test-Path $folder)) {
            Write-Host "  warning: path does not exist yet - adding anyway: $folder" -ForegroundColor Yellow
        }
    }
}

# --- Apply exclusions ---
$existing     = @((Get-MpPreference).ExclusionPath)
$existingProc = @((Get-MpPreference).ExclusionProcess)
$addedPaths   = 0
$addedProcs   = 0

Write-Host ""
Write-Host "Applying path exclusions..."

foreach ($folder in $ProjectFolders) {
    if ($existing | Where-Object { $_ -ieq $folder }) {
        Write-Host "  already excluded : $folder"
    } else {
        Add-MpPreference -ExclusionPath $folder
        Write-Host "  added            : $folder"
        $addedPaths++
    }
}

foreach ($p in $pathExclusions) {
    if ($existing | Where-Object { $_ -ieq $p }) {
        Write-Host "  already excluded : $p"
    } else {
        Add-MpPreference -ExclusionPath $p
        Write-Host "  added            : $p"
        $addedPaths++
    }
}

Write-Host ""
Write-Host "Applying process exclusions..."

foreach ($proc in $processExclusions) {
    if ($existingProc | Where-Object { $_ -ieq $proc }) {
        Write-Host "  already excluded : $proc"
    } else {
        Add-MpPreference -ExclusionProcess $proc
        Write-Host "  added            : $proc"
        $addedProcs++
    }
}

Write-Host ""
Write-Host "Done. Added $addedPaths path(s) and $addedProcs process(es)."
Write-Host "Enjoy faster build times!"
```

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
