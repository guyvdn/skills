---
description: Diagnose CPU spikes, disable telemetry services and unnecessary startup items on Windows
---

# Windows Performance Tuning

Diagnose CPU spikes and disable unnecessary services and startup items on a Windows developer machine.

## Step 1 — Find the real-time CPU offender

Use WMI perf counters for current CPU %, not cumulative totals:

```powershell
Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
  Sort-Object PercentProcessorTime -Descending |
  Where-Object { $_.PercentProcessorTime -gt 1 } |
  Select-Object -First 15 Name, PercentProcessorTime, IDProcess |
  Format-Table -AutoSize
```

> `Get-Process | Sort-Object CPU` shows cumulative seconds since start — not current load. Always confirm with WMI perf counters.

## Step 2 — Get process details

```powershell
Get-Process -Id <pid> | Select-Object Name, Id, Path, StartTime, CPU | Format-List
```

## Step 3 — Disable the offending service

```powershell
Stop-Service <ServiceName> -Force
Set-Service <ServiceName> -StartupType Disabled
```

If the process lingers after stopping the service:
```powershell
taskkill /PID <pid> /F
```

## Step 4 — Run the cleanup script

Disables known CPU-hungry and telemetry services and removes unnecessary startup items.

Ask the user to save the script below as `Disable-UnnecessaryServices.ps1` and run it from an **admin PowerShell** prompt:

```powershell
powershell -ExecutionPolicy Bypass -File .\Disable-UnnecessaryServices.ps1
```

### Script

```powershell
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Detects and disables CPU-hungry or unnecessary services and startup items
    on a Windows developer machine.

.DESCRIPTION
    Idempotent — safe to run multiple times. Skips services that are already
    disabled and startup entries that are already removed.

.EXAMPLE
    .\Disable-UnnecessaryServices.ps1
#>

function Disable-ServiceIfRunning {
    param([string]$Name, [string]$Reason)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }

    if ($svc.StartType -eq 'Disabled') {
        Write-Host "  [already disabled] $Name"
        return
    }

    Write-Host "  [$($svc.Status)] $Name - $Reason"
    if ($svc.Status -ne 'Stopped') {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    }
    Set-Service -Name $Name -StartupType Disabled
    Write-Host "       -> disabled"
}

# Resolves a service by DisplayName pattern when the internal service name is uncertain.
function Disable-ServiceByDisplayName {
    param([string]$DisplayNamePattern, [string]$Reason)
    $svc = Get-Service | Where-Object { $_.DisplayName -like $DisplayNamePattern } | Select-Object -First 1
    if (-not $svc) { return }
    Disable-ServiceIfRunning $svc.Name $Reason
}

function Remove-StartupEntry {
    param([string]$Name, [string]$Reason)
    # Check both HKCU (user-level) and HKLM (machine-wide). Script requires admin so HKLM writes are allowed.
    $keys = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    )
    foreach ($key in $keys) {
        if (Get-ItemProperty -Path $key -Name $Name -ErrorAction SilentlyContinue) {
            Write-Host "  [startup] $Name ($($key -replace 'HKCU:','HKCU' -replace 'HKLM:','HKLM')) - $Reason"
            Remove-ItemProperty -Path $key -Name $Name -ErrorAction SilentlyContinue
            Write-Host "       -> removed"
        }
    }
}

# --- 1. Audio APO drivers (common CPU spike culprits) ---
Write-Host ""
Write-Host "=== Audio APO services ==="
$apoServices = @(
    @{ Name = 'SNAPOService'; Reason = 'Sonitude APO — known CPU spinner, not needed with Bluetooth headphones' },
    @{ Name = 'CxUtilSvc';   Reason = 'Conexant audio utility — laptop speaker enhancement only' },
    @{ Name = 'CxMonSvc';    Reason = 'Conexant monitor service' }
)
foreach ($s in $apoServices) { Disable-ServiceIfRunning $s.Name $s.Reason }

# --- 2. Telemetry services ---
Write-Host ""
Write-Host "=== Telemetry & analytics services ==="
$telemetryServices = @(
    @{ Name = 'DiagTrack';                    Reason = 'Windows Connected User Experiences & Telemetry — sends data to Microsoft' },
    @{ Name = 'HPAudioAnalytics';             Reason = 'HP audio analytics — sends usage data to HP' },
    @{ Name = 'HpTouchpointAnalyticsService'; Reason = 'HP Touchpoint analytics' },
    @{ Name = 'hpLHAgent';                    Reason = 'HP Insights telemetry agent' },
    @{ Name = 'hpLHWatchdog';                 Reason = 'HP Insights watchdog' },
    @{ Name = 'dptftcs';                      Reason = 'Intel Dynamic Tuning Technology telemetry' },
    @{ Name = 'ipfsvc';                       Reason = 'Intel Innovation Platform Framework - spawns ipf_helper.exe, known CPU consumer' }
)
foreach ($s in $telemetryServices) { Disable-ServiceIfRunning $s.Name $s.Reason }

# Intel Analytics: service name varies across driver versions — resolve by DisplayName to be safe
Disable-ServiceByDisplayName '*Intel*Analytics*' 'Intel telemetry'

# --- 3. Services unused on most dev machines ---
Write-Host ""
Write-Host "=== Services typically unused on developer machines ==="
$unusedServices = @(
    @{ Name = 'W3SVC'; Reason = 'IIS web server — unusual to need on a workstation' }
)
foreach ($s in $unusedServices) { Disable-ServiceIfRunning $s.Name $s.Reason }

# --- 4. Startup items (HKCU + HKLM) ---
Write-Host ""
Write-Host "=== Unnecessary startup items ==="

# Edge and Chrome auto-launch keys have a hash suffix — match by prefix in both hives
foreach ($regKey in @("HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run")) {
    $hive = if ($regKey -like 'HKCU:*') { 'HKCU' } else { 'HKLM' }
    Get-Item $regKey -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Property | Where-Object {
        $_ -match "^MicrosoftEdgeAutoLaunch_"
    } | ForEach-Object {
        Write-Host "  [startup] $_ ($hive) - Edge silent background launch"
        Remove-ItemProperty -Path $regKey -Name $_ -ErrorAction SilentlyContinue
        Write-Host "       -> removed"
    }

    Get-Item $regKey -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Property | Where-Object {
        $_ -match "^GoogleChromeAutoLaunch_"
    } | ForEach-Object {
        Write-Host "  [startup] $_ ($hive) - Chrome silent background launch"
        Remove-ItemProperty -Path $regKey -Name $_ -ErrorAction SilentlyContinue
        Write-Host "       -> removed"
    }
}

$startupEntries = @(
    @{ Name = 'Adobe Acrobat Synchronizer'; Reason = 'Adobe Acrobat collaboration sync — not needed at every login' },
    @{ Name = 'StartLoad';                  Reason = 'Yealink Wireless Presentation Pod — only needed when presenting' },
    @{ Name = 'ClickShare';                 Reason = 'Barco ClickShare — only needed when presenting' }
)
foreach ($e in $startupEntries) { Remove-StartupEntry $e.Name $e.Reason }

# --- Summary ---
Write-Host ""
Write-Host "=== Done ==="
Write-Host "Services are stopped and disabled. Startup items are removed."
Write-Host "Changes survive reboot. Re-enable any service via:"
Write-Host "  Set-Service -Name <name> -StartupType Automatic; Start-Service <name>"
```

### Services the script disables

| Service | Description |
|---|---|
| `SNAPOService` | Sonitude audio APO — known CPU spinner, not needed with Bluetooth headphones |
| `CxUtilSvc` / `CxMonSvc` | Conexant audio utilities |
| `DiagTrack` | Windows Connected User Experiences & Telemetry |
| `HPAudioAnalytics` | HP audio analytics |
| `HpTouchpointAnalyticsService` | HP Touchpoint analytics |
| `hpLHAgent` / `hpLHWatchdog` | HP Insights telemetry agent |
| `Intel Analytics Service` | Intel telemetry |
| `dptftcs` | Intel Dynamic Tuning Technology telemetry |
| `ipfsvc` | Intel Innovation Platform Framework — spawns `ipf_helper.exe`, known CPU consumer |
| `W3SVC` | IIS web server — unusual to need on a workstation |

### Startup items the script removes

| Entry | Description |
|---|---|
| `MicrosoftEdgeAutoLaunch_*` | Edge silent background launch |
| `GoogleChromeAutoLaunch_*` | Chrome silent background launch |
| `Adobe Acrobat Synchronizer` | Acrobat collaboration sync |
| `StartLoad` | Yealink Wireless Presentation Pod |
| `ClickShare` | Barco ClickShare presentation tool |

## Gotchas

- Audio APO services (`SNAPOService`) are safe to disable even when using Bluetooth — APO only affects the laptop's built-in audio pipeline.
- To re-enable a service: `Set-Service -Name <name> -StartupType Automatic; Start-Service <name>`
- To identify which service is inside a high-CPU `svchost`: `tasklist /svc /fi "pid eq <pid>"`
- Intel Analytics is resolved automatically by DisplayName pattern — no manual action needed if the service is not present on a given machine.
- Both `HKCU` and `HKLM` startup entries are checked. `HKLM` writes are allowed because the script already enforces admin elevation.
