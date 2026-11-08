<#
.SYNOPSIS
    Shows or sets a ThinkPad's battery charge thresholds on Windows, without Vantage.

.DESCRIPTION
    Thresholds are stored per battery under
    HKLM\SOFTWARE\WOW6432Node\Lenovo\PWRMGRV\ConfKeys\Data\<battery-id> and pushed to the
    embedded controller by PowerMgr.exe (Lenovo Power Manager, started by the scheduled task
    \Lenovo\Power Manager\Background monitor). This script writes the values, makes sure that
    task is enabled, restarts PowerMgr.exe so it applies them, and watches the battery.
    Run elevated.

.PARAMETER Status
    Only report: stored thresholds, PowerMgr.exe, Lenovo tasks, battery state. Changes nothing.

.PARAMETER Start
    Start charging when the battery falls below this percentage.

.PARAMETER Stop
    Stop charging at this percentage. Use -Start 95 -Stop 100 for a full charge:
    switching the thresholds off (Control = 0) is not pushed to the EC.

.EXAMPLE
    .\Set-ThinkPadChargeThreshold.ps1 -Status

.EXAMPLE
    .\Set-ThinkPadChargeThreshold.ps1 -Start 95 -Stop 100
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Status')][switch]$Status,
    [Parameter(ParameterSetName = 'Set', Mandatory)][ValidateRange(0, 99)][int]$Start,
    [Parameter(ParameterSetName = 'Set', Mandatory)][ValidateRange(1, 100)][int]$Stop
)
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated PowerShell (or an admin SSH session).' }

$root = 'HKLM:\SOFTWARE\WOW6432Node\Lenovo\PWRMGRV\ConfKeys\Data'
$keys = @(Get-ChildItem $root -ErrorAction SilentlyContinue | Where-Object { $null -ne (Get-ItemProperty $_.PSPath).ChargeStopPercentage })
$monitor = @{ TaskPath = '\Lenovo\Power Manager\'; TaskName = 'Background monitor' }

function Get-Battery {
    $st = Get-CimInstance -Namespace root\wmi BatteryStatus
    $full = (Get-CimInstance -Namespace root\wmi BatteryFullChargedCapacity).FullChargedCapacity
    [pscustomobject]@{
        Online   = $st.PowerOnline
        Charging = $st.Charging
        Rate     = $st.ChargeRate
        Percent  = if ($full) { 100 * $st.RemainingCapacity / $full } else { 0 }
    }
}
function Format-Battery($b) { '  battery: online={0} charging={1} rate={2} mW, {3:N0} %' -f $b.Online, $b.Charging, $b.Rate, $b.Percent }

function Show-State {
    if (-not $keys) { '  no per-battery threshold key under ' + $root }
    foreach ($k in $keys) {
        $v = Get-ItemProperty $k.PSPath
        '  {0}: start control={1} at {2} %, stop control={3} at {4} %' -f $k.PSChildName, $v.ChargeStartControl, $v.ChargeStartPercentage, $v.ChargeStopControl, $v.ChargeStopPercentage
    }
    '  PowerMgr.exe running: ' + [bool](Get-Process PowerMgr -ErrorAction SilentlyContinue)
    Get-ScheduledTask -TaskPath '\Lenovo\Power Manager\', '\Lenovo\UDC\' -ErrorAction SilentlyContinue |
        ForEach-Object { '  task {0}{1}: {2}' -f $_.TaskPath, $_.TaskName, $_.State }
    Format-Battery (Get-Battery)
}

if ($PSCmdlet.ParameterSetName -eq 'Status') { Show-State; return }

if ($Start -ge $Stop) { throw "-Start ($Start) must be lower than -Stop ($Stop)." }
if (-not $keys) {
    throw "No per-battery key under $root. Install the 'Lenovo Power and Battery' driver (Lenovo System Update or support.lenovo.com), sign out and in, then run -Status again."
}
if (-not (Get-ScheduledTask @monitor -ErrorAction SilentlyContinue)) {
    throw "Scheduled task '\Lenovo\Power Manager\Background monitor' not found: the Lenovo Power and Battery driver is missing or incomplete."
}

# Back up, then write. Both controls stay 1: Control = 0 is not applied to the EC.
$backupDir = Join-Path $env:ProgramData 'ThinkPadChargeThreshold'
New-Item -ItemType Directory -Force $backupDir | Out-Null
foreach ($k in $keys) {
    $file = Join-Path $backupDir ('{0}-{1:yyyyMMdd-HHmmss}.reg' -f $k.PSChildName, (Get-Date))
    & reg.exe export ($k.Name) $file /y | Out-Null
    Set-ItemProperty $k.PSPath ChargeStartControl 1
    Set-ItemProperty $k.PSPath ChargeStartPercentage $Start
    Set-ItemProperty $k.PSPath ChargeStopControl 1
    Set-ItemProperty $k.PSPath ChargeStopPercentage $Stop
    "  $($k.PSChildName): set to start $Start / stop $Stop (backup $file)"
}

# PowerMgr.exe applies the values; a debloat may have disabled the tasks that start it.
Get-ScheduledTask -TaskPath '\Lenovo\Power Manager\', '\Lenovo\UDC\' -ErrorAction SilentlyContinue | Enable-ScheduledTask | Out-Null
Get-Process PowerMgr -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Start-ScheduledTask @monitor

# Charging only resumes if the battery is below the new start value.
for ($i = 1; $i -le 6; $i++) {
    Start-Sleep -Seconds 10
    $b = Get-Battery
    Format-Battery $b
    if ($b.Charging -or $b.Percent -ge $Start) { break }
}
Show-State
