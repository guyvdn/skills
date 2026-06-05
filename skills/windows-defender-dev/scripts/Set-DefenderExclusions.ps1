#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Adds Windows Defender exclusions for a Visual Studio / VS Code / JetBrains / SSMS developer machine.

.DESCRIPTION
    Idempotent — safe to run multiple times. Skips exclusions already present.
    Path comparison is case-insensitive to match Windows filesystem behaviour.
    Covers: VS 2022 (v17 + v18 Insiders), VS Code, .NET SDK, NuGet, MSBuild, JetBrains Rider,
    SQL Server Management Studio, and one or more user-supplied project folders.

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

    # Program Files (x64)
    'C:\Program Files\Microsoft Visual Studio',
    'C:\Program Files\Microsoft VS Code',
    'C:\Program Files\dotnet',
    'C:\Program Files\Microsoft SDKs',
    'C:\Program Files\Microsoft SQL Server',

    # Program Files (x86)
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
