<#
.SYNOPSIS
    Turns off automatic panel dimming: ambient-light adaptive brightness and
    content-adaptive dimming (Intel DPST / AMD Vari-Bright).
.DESCRIPTION
    Idempotent - re-running when everything is already correct logs one line and exits.

    The GPU registry values are read by the display driver at init, so changes take
    effect at the next driver load. -RestartAdapter forces that now (the screen blanks
    for a second or two).

    Windows feature updates re-stage the graphics driver package and reset these values.
    -InstallTask copies this script to $env:ProgramData\AdaptiveDimmingFix and registers
    a SYSTEM scheduled task that re-applies it at every boot, so the change self-heals.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Disable-AdaptiveDimming.ps1 -RestartAdapter
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Disable-AdaptiveDimming.ps1 -InstallTask
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    # Reload the display driver so the change applies without a reboot.
    [switch]$RestartAdapter,

    # Deploy to ProgramData and register the at-boot re-apply task.
    [switch]$InstallTask,

    # Remove the deployed copy and the scheduled task.
    [switch]$UninstallTask
)

$ErrorActionPreference = 'Stop'

$TaskName  = 'Disable Adaptive Dimming'
$InstallDir = Join-Path $env:ProgramData 'AdaptiveDimmingFix'
$LogFile   = Join-Path $InstallDir 'adaptive-dimming.log'
$ClassRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

function Write-Log {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $LogFile -Value $line
    Write-Verbose $line
}

# --- Uninstall ---------------------------------------------------------------
if ($UninstallTask) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
    } else {
        Write-Host "No scheduled task '$TaskName' to remove." -ForegroundColor Yellow
    }
    $deployed = Join-Path $InstallDir 'Disable-AdaptiveDimming.ps1'
    if (Test-Path $deployed) { Remove-Item $deployed -Force; Write-Host "Removed $deployed." -ForegroundColor Green }
    return
}

# --- Install -----------------------------------------------------------------
if ($InstallTask) {
    $deployed = Join-Path $InstallDir 'Disable-AdaptiveDimming.ps1'
    # Deploy outside the repo: a boot task must not depend on a working copy that
    # can be moved, renamed or deleted.
    if ($PSCommandPath -ne $deployed) { Copy-Item -LiteralPath $PSCommandPath -Destination $deployed -Force }

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $deployed)
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT1M'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # Laptop-safe: the default settings skip the run on battery and kill it on unplug.
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force `
        -Description 'Re-applies "no automatic panel dimming". Windows feature updates re-stage the graphics driver and reset it.' | Out-Null

    Write-Host "Installed '$TaskName' -> $deployed" -ForegroundColor Green
    Write-Log  "Installed scheduled task '$TaskName'."
}

# --- Apply -------------------------------------------------------------------
$changed = $false

# Ambient-light adaptive brightness, both power sources.
& powercfg.exe -setacvalueindex SCHEME_CURRENT SUB_VIDEO ADAPTBRIGHT 0 | Out-Null
& powercfg.exe -setdcvalueindex SCHEME_CURRENT SUB_VIDEO ADAPTBRIGHT 0 | Out-Null
& powercfg.exe -setactive SCHEME_CURRENT | Out-Null

# Content-adaptive dimming, per GPU vendor.
$Desired = @{
    'Intel.*Graphics' = [ordered]@{
        PowerDpstAggressivenessLevel = @{ Type = 'Binary'; Value = [byte[]](0, 0, 0, 0) }
        Dpst6_3ApplyExtraDimming     = @{ Type = 'DWord';  Value = 0 }
    }
    'AMD|Radeon'      = [ordered]@{
        PP_VariBrightEnableDefault   = @{ Type = 'DWord';  Value = 0 }
    }
}

# Match on DriverDesc rather than assuming key 0000 - the index moves when a driver
# package is re-staged, which is exactly the situation this script exists for.
$adapters = @(Get-ChildItem $ClassRoot -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.DriverDesc) { [pscustomobject]@{ Key = $_.PSChildName; Path = $_.PSPath; Desc = $p.DriverDesc; Props = $p } }
})

if (-not $adapters) { Write-Log 'No display adapter class keys found - nothing to do.'; return }

foreach ($a in $adapters) {
    foreach ($pattern in $Desired.Keys) {
        if ($a.Desc -notmatch $pattern) { continue }

        foreach ($name in $Desired[$pattern].Keys) {
            $want = $Desired[$pattern][$name]
            $have = $a.Props.$name

            # Only write values the driver already exposes, plus the Intel DPST level,
            # so we do not invent settings on hardware that has no such knob.
            if ($null -eq $have -and $name -ne 'PowerDpstAggressivenessLevel') { continue }

            $isCorrect = if ($want.Type -eq 'Binary') {
                ($have -is [byte[]]) -and -not (Compare-Object $have $want.Value)
            } else {
                $have -eq $want.Value
            }
            if ($isCorrect) { continue }

            Set-ItemProperty -LiteralPath $a.Path -Name $name -Value $want.Value -Type $want.Type
            $before = if ($null -eq $have) { '<unset>' } else { $have -join ',' }
            Write-Log ('{0} [{1}]: {2} = {3} -> {4}' -f $a.Desc, $a.Key, $name, $before, ($want.Value -join ','))
            $changed = $true
        }
    }
}

if ($changed) {
    Write-Log 'Values re-applied; effective once the display driver reloads.'
} else {
    Write-Log 'Already correct - no change.'
}

if ($RestartAdapter) {
    $dev = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue |
           Where-Object { $_.FriendlyName -match 'Intel.*Graphics|AMD|Radeon' } | Select-Object -First 1
    if ($dev) {
        Write-Log ('Restarting {0}' -f $dev.FriendlyName)
        & pnputil.exe /restart-device $dev.InstanceId | Out-Null
        Write-Log 'Adapter restarted.'
    } else {
        Write-Log 'Adapter not found for restart.'
    }
}

Write-Host ('Done. Log: {0}' -f $LogFile) -ForegroundColor Green
