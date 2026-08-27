#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Detects and disables CPU-hungry or unnecessary services and startup items
    on a Windows developer machine.

.DESCRIPTION
    Idempotent — safe to run multiple times. Skips services that are already
    disabled and startup entries that are already removed.

.PARAMETER IncludeIIS
    Also disable W3SVC (IIS). Off by default: plenty of developer machines host
    sites on local IIS, and a workstation that never uses it pays almost nothing
    for an idle W3SVC. Opt in only when you know IIS is not in use.

.EXAMPLE
    .\Disable-UnnecessaryServices.ps1

.EXAMPLE
    .\Disable-UnnecessaryServices.ps1 -IncludeIIS
#>

param([switch]$IncludeIIS)

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
    @{ Name = 'dptftcs';                      Reason = 'Intel Dynamic Tuning Technology TELEMETRY service - the display name says Telemetry; the tuning itself lives elsewhere' }
)
foreach ($s in $telemetryServices) { Disable-ServiceIfRunning $s.Name $s.Reason }

# Intel Analytics: service name varies across driver versions — resolve by DisplayName to be safe
Disable-ServiceByDisplayName '*Intel*Analytics*' 'Intel telemetry'

# NOT disabled: ipfsvc (Intel Innovation Platform Framework).
#
# Earlier versions of this script disabled it as "telemetry, a known CPU
# consumer". Both halves were wrong. Its display name is "Intel(R) Innovation
# Platform Framework Service" — no telemetry in it — and on modern Intel mobile
# parts IPF is the dynamic power and thermal manager: it trims sustained power
# limits so the chassis does not sit hot. Measured over 3 minutes on a 13th-gen
# P-series laptop, ipf_helper.exe and ipf_uf.exe both held 0% CPU.
#
# Disabling it does not save CPU and removes dynamic thermal management, which
# is the opposite of what someone chasing a constantly-spinning fan wants.
Write-Host ""
Write-Host "=== Deliberately left running ==="
$ipf = Get-Service -Name 'ipfsvc' -ErrorAction SilentlyContinue
if ($ipf) {
    Write-Host "  ipfsvc ($($ipf.Status), $($ipf.StartType)) - Intel dynamic power/thermal manager, not telemetry"
    if ($ipf.StartType -eq 'Disabled') {
        Write-Host "       -> currently DISABLED. If an older run of this script did that, re-enable it:"
        Write-Host "          Set-Service -Name ipfsvc -StartupType Automatic; Start-Service ipfsvc"
    }
}

# --- 3. Services unused on most dev machines ---
Write-Host ""
Write-Host "=== Services typically unused on developer machines ==="
if ($IncludeIIS) {
    Disable-ServiceIfRunning 'W3SVC' 'IIS web server — disabled because -IncludeIIS was passed'
} else {
    $iis = Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue
    if ($iis -and $iis.StartType -ne 'Disabled') {
        Write-Host "  [skipped] W3SVC (IIS) is $($iis.Status). Pass -IncludeIIS to disable it."
    }
}

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
