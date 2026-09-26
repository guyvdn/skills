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
    Visual Studio, IDEs and build agents first. If a running process still references an
    old cache path (e.g. an MCP server launched through npx runs out of npm-cache\_npx),
    that cache is copied instead of moved, and the old folder is left for you to delete
    after the process exits.
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
    [ValidateSet('NuGet', 'Npm', 'Pnpm', 'Pip', 'Uv', 'Cargo', 'Vcpkg', 'Gradle', 'Maven')]
    [string[]]$Caches = @('NuGet', 'Npm', 'Pnpm', 'Pip', 'Uv', 'Cargo', 'Vcpkg', 'Gradle', 'Maven'),

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
    # pnpm 11 reads config from pnpm_config_* env vars; npm_config_store_dir is ignored.
    # The store keeps a version subfolder (v11) inside store-dir, so moving the whole old
    # store folder lands it at <target>\v11 - exactly where pnpm will look.
    @{ Cache = 'Pnpm';   Name = 'pnpm_config_store_dir';      Sub = 'pnpm';            Old = @("$env:LOCALAPPDATA\pnpm\store") }
    @{ Cache = 'Pip';    Name = 'PIP_CACHE_DIR';              Sub = 'pip';             Old = @("$env:LOCALAPPDATA\pip\Cache") }
    @{ Cache = 'Uv';     Name = 'UV_CACHE_DIR';               Sub = 'uv';              Old = @("$env:LOCALAPPDATA\uv\cache") }
    @{ Cache = 'Cargo';  Name = 'CARGO_HOME';                 Sub = 'cargo';           Old = @("$env:USERPROFILE\.cargo") }
    @{ Cache = 'Vcpkg';  Name = 'VCPKG_DEFAULT_BINARY_CACHE'; Sub = 'vcpkg';           Old = @("$env:LOCALAPPDATA\vcpkg\archives", "$env:APPDATA\vcpkg\archives") }
    @{ Cache = 'Gradle'; Name = 'GRADLE_USER_HOME';           Sub = 'gradle';          Old = @("$env:USERPROFILE\.gradle") }
    @{ Cache = 'Maven';  Name = 'MAVEN_OPTS';                 Sub = 'maven';           Old = @("$env:USERPROFILE\.m2\repository"); Template = '-Dmaven.repo.local={0}' }
)

# Processes whose executable or command line points into a folder. Moving a cache out
# from under a live process breaks it (npx-launched MCP servers run from npm-cache\_npx).
# WhatIf is suspended for the CimCmdlets auto-import only; otherwise its alias setup
# prints a dozen "What if: Set Alias" lines.
$procs = @()
if ($Move) {
    $savedWhatIf = $WhatIfPreference; $WhatIfPreference = $false
    try { Import-Module CimCmdlets -ErrorAction SilentlyContinue } finally { $WhatIfPreference = $savedWhatIf }
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
}
function Get-ProcessesUsing([string]$Path) {
    $p = [regex]::Escape($Path.TrimEnd('\'))
    @($procs | Where-Object { "$($_.ExecutablePath) $($_.CommandLine)" -match "(?i)$p(\\|""|\s|$)" })
}

$changed = 0
$leftBehind = @()
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
                # @() at the call site: PowerShell 5.1 unrolls a one-element array to a bare
                # CimInstance, whose .Count is $null - the in-use check would silently pass.
                $users = @(Get-ProcessesUsing $old)
                if ($users.Count) {
                    $names = ($users | ForEach-Object { "$($_.Name) ($($_.ProcessId))" }) -join ', '
                    if ($PSCmdlet.ShouldProcess("$old -> $target", 'robocopy (copy - in use)')) {
                        Write-Warning "  $old is in use by $names - copying instead of moving."
                        & robocopy $old $target /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
                        if ($LASTEXITCODE -ge 8) { Write-Warning "  robocopy returned $LASTEXITCODE for $old - check for locked files." }
                        $leftBehind += $old
                    }
                } elseif ($PSCmdlet.ShouldProcess("$old -> $target", 'robocopy /MOVE')) {
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

if ($leftBehind.Count) {
    Write-Host ''
    Write-Host 'Copied, not moved (in use) - delete these once the processes above have exited:' -ForegroundColor Yellow
    $leftBehind | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}

if ($Caches -contains 'Pnpm') {
    Write-Host ''
    Write-Host 'pnpm note: set via pnpm_config_store_dir rather than "pnpm config set store-dir", which' -ForegroundColor DarkGray
    Write-Host 'refuses to run when pnpm''s global bin directory is not on PATH. Verify from a folder on the' -ForegroundColor DarkGray
    Write-Host 'Dev Drive with: pnpm store path. Old per-drive stores (<drive>:\.pnpm-store) are not moved.' -ForegroundColor DarkGray
}

if ($Caches -contains 'NuGet') {
    Write-Host ''
    Write-Host 'NuGet note: NUGET_PACKAGES overrides globalPackagesFolder in every NuGet.config,' -ForegroundColor DarkGray
    Write-Host 'including repository-specific settings. For a single repo, prefer globalPackagesFolder' -ForegroundColor DarkGray
    Write-Host 'in NuGet.config. Verify with: dotnet nuget locals global-packages --list' -ForegroundColor DarkGray
}
