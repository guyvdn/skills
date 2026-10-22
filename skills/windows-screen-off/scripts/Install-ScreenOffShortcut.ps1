<#
.SYNOPSIS
    Adds a global keyboard shortcut (default Ctrl+Alt+O) that turns off every monitor.
.DESCRIPTION
    Copies Invoke-ScreenOff.ps1 to $env:LOCALAPPDATA\ScreenOff and creates a Start Menu
    shortcut "Screen Off" with a hotkey. No background process: Explorer handles
    hotkeys on .lnk files, but only for shortcuts on the Desktop or in the Start Menu.

    Idempotent - re-running overwrites the deployed script and the shortcut.
    No admin needed.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Install-ScreenOffShortcut.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Install-ScreenOffShortcut.ps1 -Hotkey 'CTRL+ALT+F12'
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Install-ScreenOffShortcut.ps1 -Uninstall
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    # WScript.Shell hotkey syntax, e.g. 'CTRL+ALT+O'. An unknown key name throws on save.
    [ValidatePattern('^((CTRL|ALT|SHIFT)\+){2,3}[A-Z0-9]+$')]
    [string]$Hotkey = 'CTRL+ALT+O',

    # Remove the shortcut and the deployed script.
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:LOCALAPPDATA 'ScreenOff'
$Deployed   = Join-Path $InstallDir 'Invoke-ScreenOff.ps1'
$LnkPath    = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Screen Off.lnk'

if ($Uninstall) {
    foreach ($p in $LnkPath, $InstallDir) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force; Write-Host "Removed $p." -ForegroundColor Green }
    }
    return
}

# Deploy outside the repo: the shortcut must not depend on a working copy that can move.
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Invoke-ScreenOff.ps1') -Destination $Deployed -Force

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($LnkPath)
$lnk.TargetPath   = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$lnk.Arguments    = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Deployed`""
$lnk.WindowStyle  = 7   # minimized - with -WindowStyle Hidden this keeps the console flash to a minimum
$lnk.Hotkey       = $Hotkey
$lnk.IconLocation = (Join-Path $env:WINDIR 'System32\imageres.dll') + ',-1035'
$lnk.Description  = "Turn off all monitors ($Hotkey)"
$lnk.Save()

Write-Host "Screen Off installed: $($shell.CreateShortcut($LnkPath).Hotkey) -> $Deployed" -ForegroundColor Green
