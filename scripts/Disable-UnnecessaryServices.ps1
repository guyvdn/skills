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
