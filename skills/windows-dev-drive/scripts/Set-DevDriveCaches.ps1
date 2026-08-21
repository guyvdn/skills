<#
.SYNOPSIS
    Redirects developer package caches onto a Dev Drive by setting the environment
    variables each tool honours, and optionally moving existing cache content.
.DESCRIPTION
    Idempotent - re-running with the same arguments changes nothing. Supports -WhatIf.

    Defaults to User scope (per-user, no elevation needed, and keeps per-user ACLs on a
    multi-user machine). Use -Scope Machine for a system-wide setx /M equivalent; that
    requires an elevated session.

    Existing content is moved with robocopy /MOVE only when -Move is passed. Close
    Visual Studio, IDEs and build agents first.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Set-DevDriveCaches.ps1 -DriveLetter D -WhatIf
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Set-DevDriveCaches.ps1 -DriveLetter D -Caches NuGet,Npm -Move
#>
#Requires -Version 5.1
# PositionalBinding = $false: every argument must be named. Without it,
# 'powershell -File ... -Caches Npm Pip' silently binds 'Pip' to -Root.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', PositionalBinding = $false)]
param(
    # Dev Drive to redirect caches onto.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter,

    # Root folder for the caches. Defaults to <drive>:\packages\<username>, a per-user
    # folder as Microsoft recommends for multi-user devices.
    [string]$Root,

    # Which caches to redirect. Default: all of them.
    [ValidateSet('NuGet', 'Npm', 'Pip', 'Cargo', 'Vcpkg', 'Gradle', 'Maven')]
    [string[]]$Caches = @('NuGet', 'Npm', 'Pip', 'Cargo', 'Vcpkg', 'Gradle', 'Maven'),

    # User (default, no elevation) or Machine (elevated, equivalent to setx /M).
    [ValidateSet('User', 'Machine')]
    [string]$Scope = 'User',

    # Move existing cache content to the new location with robocopy /MOVE.
    [switch]$Move,

    # Set the variables even if the target volume is not a Dev Drive.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$drive = "$($DriveLetter.ToUpper()):"

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Scope -eq 'Machine' -and -not (Test-Elevated)) {
    throw "-Scope Machine needs an elevated PowerShell session."
}

# --- Validate the target volume ---------------------------------------------
$vol = Get-Volume -DriveLetter $DriveLetter.ToUpper() -ErrorAction SilentlyContinue
if (-not $vol) { throw "Drive $drive does not exist." }
if ($vol.FileSystemType -ne 'ReFS' -and -not $Force) {
    throw "$drive is $($vol.FileSystemType), not a ReFS Dev Drive. Pass -Force to redirect caches there anyway."
}
$trust = & fsutil devdrv query $drive 2>&1 | Out-String
if ($trust -match 'not a trusted') {
    Write-Warning "$drive is an UNTRUSTED Dev Drive - Defender still scans it synchronously. Run: fsutil devdrv trust $drive"
}

if (-not $Root) { $Root = Join-Path $drive "packages\$env:USERNAME" }
if (-not [IO.Path]::IsPathRooted($Root)) {
    throw "-Root must be an absolute path (got '$Root')."
}
Write-Host "Cache root: $Root  (scope: $Scope)" -ForegroundColor Cyan

# name = env var, path = target subfolder, old = existing default location(s),
# value = literal value to store (defaults to the path).
$plan = @(
    @{ Cache = 'NuGet';  Name = 'NUGET_PACKAGES';             Sub = '.nuget\packages'; Old = @("$env:USERPROFILE\.nuget\packages") }
    @{ Cache = 'Npm';    Name = 'npm_config_cache';           Sub = 'npm';             Old = @("$env:APPDATA\npm-cache", "$env:LOCALAPPDATA\npm-cache") }
    @{ Cache = 'Pip';    Name = 'PIP_CACHE_DIR';              Sub = 'pip';             Old = @("$env:LOCALAPPDATA\pip\Cache") }
    @{ Cache = 'Cargo';  Name = 'CARGO_HOME';                 Sub = 'cargo';           Old = @("$env:USERPROFILE\.cargo") }
    @{ Cache = 'Vcpkg';  Name = 'VCPKG_DEFAULT_BINARY_CACHE'; Sub = 'vcpkg';           Old = @("$env:LOCALAPPDATA\vcpkg\archives", "$env:APPDATA\vcpkg\archives") }
    @{ Cache = 'Gradle'; Name = 'GRADLE_USER_HOME';           Sub = 'gradle';          Old = @("$env:USERPROFILE\.gradle") }
    @{ Cache = 'Maven';  Name = 'MAVEN_OPTS';                 Sub = 'maven';           Old = @("$env:USERPROFILE\.m2\repository"); Template = '-Dmaven.repo.local={0}' }
)

$changed = 0
foreach ($item in $plan | Where-Object { $Caches -contains $_.Cache }) {
    $target = Join-Path $Root $item.Sub
    $value = if ($item.Template) { $item.Template -f $target } else { $target }
    $current = [Environment]::GetEnvironmentVariable($item.Name, $Scope)

    if ($current -eq $value) {
        Write-Host "  = $($item.Name) already -> $value" -ForegroundColor DarkGray
        continue
    }
    if ($current -and $item.Cache -eq 'Maven' -and $current -notmatch 'maven\.repo\.local') {
        # MAVEN_OPTS is a general JVM options string; don't silently drop other flags.
        Write-Warning "  MAVEN_OPTS already set to '$current'. Append '$value' by hand instead of overwriting."
        continue
    }

    if (-not (Test-Path $target)) {
        if ($PSCmdlet.ShouldProcess($target, 'Create directory')) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        }
    }

    if ($Move) {
        foreach ($old in $item.Old) {
            if ((Test-Path $old) -and ((Get-ChildItem -LiteralPath $old -Force -ErrorAction SilentlyContinue).Count -gt 0)) {
                if ($PSCmdlet.ShouldProcess("$old -> $target", 'robocopy /MOVE')) {
                    Write-Host "  moving $old -> $target" -ForegroundColor Yellow
                    & robocopy $old $target /E /MOVE /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
                    if ($LASTEXITCODE -ge 8) { Write-Warning "  robocopy returned $LASTEXITCODE for $old - check for locked files." }
                }
            }
        }
    }

    if ($PSCmdlet.ShouldProcess("$($item.Name) ($Scope)", "Set to $value")) {
        [Environment]::SetEnvironmentVariable($item.Name, $value, $Scope)
        Write-Host "  + $($item.Name) -> $value" -ForegroundColor Green
        $changed++
    }
}

Write-Host ''
if ($changed) {
    Write-Host "$changed variable(s) set. Restart open consoles, IDEs and Visual Studio (or reboot) for the new values to apply." -ForegroundColor Cyan
} else {
    Write-Host 'Nothing changed.' -ForegroundColor Cyan
}

if ($Caches -contains 'NuGet') {
    Write-Host ''
    Write-Host 'NuGet note: NUGET_PACKAGES overrides globalPackagesFolder in every NuGet.config,' -ForegroundColor DarkGray
    Write-Host 'including repository-specific settings. For a single repo, prefer globalPackagesFolder' -ForegroundColor DarkGray
    Write-Host 'in NuGet.config. Verify with: dotnet nuget locals global-packages --list' -ForegroundColor DarkGray
}
