<#
.SYNOPSIS
    Reports every Windows and GPU mechanism that can dim a laptop panel on its own.
.DESCRIPTION
    Read-only - changes nothing. Covers ambient-light adaptive brightness, content-adaptive
    dimming (Intel DPST / AMD Vari-Bright), battery-saver dimming, and whether a
    re-apply task is installed. Prints PASS / WARN / FAIL and a list of suggested fixes.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Test-DisplayDimming.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param()

$script:Fixes = New-Object System.Collections.Generic.List[string]

function Write-Result {
    param(
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [string]$Message,
        [string]$Fix
    )
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    Write-Host ('  [{0}] {1}' -f $Status, $Message) -ForegroundColor $color
    if ($Fix) { $script:Fixes.Add($Fix) }
}

function Get-PowerCfgIndex {
    <# Returns @{AC=<int>; DC=<int>} or $null. powercfg exits 0 and prints only the
       scheme header when a setting is hidden on the active scheme, so the match
       must be checked rather than the exit code. #>
    param([string]$SubGroup, [string]$Setting)
    $out = powercfg -query SCHEME_CURRENT $SubGroup $Setting 2>$null
    if (-not $out) { return $null }
    $ac = [regex]::Match(($out -join "`n"), 'Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)')
    $dc = [regex]::Match(($out -join "`n"), 'Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+)')
    if (-not $ac.Success -or -not $dc.Success) { return $null }
    @{ AC = [Convert]::ToInt32($ac.Groups[1].Value, 16); DC = [Convert]::ToInt32($dc.Groups[1].Value, 16) }
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$ClassRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'

Write-Host "`n=== Display auto-dimming audit ===" -ForegroundColor Cyan
if (-not (Test-Elevated)) {
    Write-Host '  Not elevated - driver registry values may be unreadable.' -ForegroundColor Yellow
}

# --- 1. Ambient light sensor -------------------------------------------------
Write-Host "`n-- Ambient light sensor (adaptive brightness)" -ForegroundColor Cyan

$sensors = @(Get-PnpDevice -Class Sensor -ErrorAction SilentlyContinue | Where-Object Status -eq 'OK')
if ($sensors) {
    Write-Result INFO ('Sensor devices present: {0}' -f (($sensors.FriendlyName | Sort-Object -Unique) -join ', '))
} else {
    Write-Result INFO 'No sensor devices - ambient-light dimming is not possible on this machine.'
}

$adapt = Get-PowerCfgIndex -SubGroup SUB_VIDEO -Setting FBD9AA66-9553-4097-BA44-ED6E9D65EAB8
if ($adapt) {
    foreach ($m in @(@{ N = 'AC'; V = $adapt.AC }, @{ N = 'DC (battery)'; V = $adapt.DC })) {
        if ($m.V -eq 0) {
            Write-Result PASS ('Adaptive brightness OFF on {0}.' -f $m.N)
        } else {
            Write-Result FAIL ('Adaptive brightness ON on {0}.' -f $m.N) `
                'Disable-AdaptiveDimming.ps1 (or Settings > System > Power > screen brightness).'
        }
    }
} else {
    Write-Result INFO 'Adaptive brightness setting not exposed by the active power scheme.'
}

# --- 2. Content-adaptive dimming --------------------------------------------
Write-Host "`n-- Content-adaptive dimming (CABC / DPST / Vari-Bright)" -ForegroundColor Cyan

$adapters = @(Get-ChildItem $ClassRoot -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.DriverDesc) { [pscustomobject]@{ Key = $_.PSChildName; Path = $_.PSPath; Desc = $p.DriverDesc; Props = $p } }
})

if (-not $adapters) { Write-Result WARN 'No display adapter class keys readable (run elevated).' }

foreach ($a in $adapters) {
    if ($a.Desc -match 'Intel.*Graphics') {
        $lvl  = $a.Props.PowerDpstAggressivenessLevel
        $lvl0 = if ($lvl -is [byte[]] -and $lvl.Count) { [int]$lvl[0] } elseif ($null -ne $lvl) { [int]$lvl } else { $null }
        $xtra = $a.Props.Dpst6_3ApplyExtraDimming

        if ($null -eq $lvl0) {
            Write-Result INFO ('{0} [{1}]: DPST aggressiveness not set (driver default applies).' -f $a.Desc, $a.Key)
        } elseif ($lvl0 -eq 0) {
            Write-Result PASS ('{0} [{1}]: DPST aggressiveness 0 (off).' -f $a.Desc, $a.Key)
        } else {
            Write-Result FAIL ('{0} [{1}]: DPST aggressiveness {2}/6 - panel dims on dark content.' -f $a.Desc, $a.Key, $lvl0) `
                'Disable-AdaptiveDimming.ps1 -RestartAdapter'
        }

        if ($xtra -eq 1) {
            Write-Result FAIL ('{0} [{1}]: Dpst6_3ApplyExtraDimming = 1.' -f $a.Desc, $a.Key) `
                'Disable-AdaptiveDimming.ps1 -RestartAdapter'
        } elseif ($xtra -eq 0) {
            Write-Result PASS ('{0} [{1}]: Dpst6_3ApplyExtraDimming = 0.' -f $a.Desc, $a.Key)
        }
    }

    $vb = $a.Props.PSObject.Properties | Where-Object Name -match 'VariBright'
    foreach ($v in $vb) {
        if ($v.Value -in @(0, '0')) { Write-Result PASS ('{0} [{1}]: {2} = 0.' -f $a.Desc, $a.Key, $v.Name) }
        else { Write-Result FAIL ('{0} [{1}]: {2} = {3} - AMD Vari-Bright active.' -f $a.Desc, $a.Key, $v.Name, $v.Value) `
                'Disable-AdaptiveDimming.ps1 -RestartAdapter' }
    }
}

# --- 3. Battery saver dimming ------------------------------------------------
Write-Host "`n-- Battery saver" -ForegroundColor Cyan
$es = Get-PowerCfgIndex -SubGroup SUB_ENERGYSAVER -Setting ESBRIGHTNESS
if ($null -eq $es) {
    Write-Result INFO 'Battery-saver brightness setting not exposed by the active power scheme.'
} elseif ($es.DC -ge 100) {
    Write-Result PASS 'Battery saver does not reduce brightness.'
} else {
    Write-Result WARN ('Battery saver drops brightness to {0}% on battery.' -f $es.DC) `
        'powercfg -setdcvalueindex SCHEME_CURRENT SUB_ENERGYSAVER ESBRIGHTNESS 100; powercfg -setactive SCHEME_CURRENT'
}

# --- 4. Persistence ----------------------------------------------------------
Write-Host "`n-- Re-apply task" -ForegroundColor Cyan
$task = Get-ScheduledTask -TaskName 'Disable Adaptive Dimming' -ErrorAction SilentlyContinue
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName 'Disable Adaptive Dimming'
    Write-Result PASS ('Task installed, state {0}, last result {1}.' -f $task.State, $info.LastTaskResult)
} else {
    Write-Result WARN 'No re-apply task - a Windows feature update will silently reset these.' `
        'Disable-AdaptiveDimming.ps1 -InstallTask'
}

# --- Summary -----------------------------------------------------------------
Write-Host "`n=== Suggested fixes ===" -ForegroundColor Cyan
if ($script:Fixes.Count -eq 0) {
    Write-Host '  Nothing to do.' -ForegroundColor Green
} else {
    $i = 1
    foreach ($f in ($script:Fixes | Select-Object -Unique)) { Write-Host ('  {0}. {1}' -f $i++, $f); }
}
Write-Host ''
