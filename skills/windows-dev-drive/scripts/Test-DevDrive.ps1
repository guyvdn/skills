<#
.SYNOPSIS
    Audits Dev Drive configuration: volumes, trust, attached filters, Defender
    performance mode, overlapping Defender exclusions, and package cache redirects.
.DESCRIPTION
    Read-only — changes nothing. Prints PASS / WARN / FAIL lines and a list of
    suggested fixes. Run elevated for complete output (fsutil devdrv query needs admin).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Test-DevDrive.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Test-DevDrive.ps1 -DriveLetter D
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    # Limit the per-volume checks to a single drive letter.
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter
)

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

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$elevated = Test-Elevated
Write-Host "`n=== Dev Drive audit ===" -ForegroundColor Cyan
if (-not $elevated) {
    Write-Host '  Not elevated - fsutil devdrv queries will be incomplete.' -ForegroundColor Yellow
}

# --- 1. Prerequisites --------------------------------------------------------
Write-Host "`n-- Prerequisites" -ForegroundColor Cyan
$os = [Environment]::OSVersion.Version
$build = '{0}.{1}.{2}.{3}' -f $os.Major, $os.Minor, $os.Build, $os.Revision
if ($os.Build -gt 22621 -or ($os.Build -eq 22621 -and $os.Revision -ge 2338)) {
    Write-Result PASS "Windows build $build supports Dev Drive."
} else {
    Write-Result FAIL "Windows build $build is below the minimum 10.0.22621.2338." `
        'Run Windows Update to reach build 22621.2338 or later.'
}

$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
if ($ramGB -ge 16) { Write-Result PASS "$ramGB GB RAM (ReFS uses slightly more memory than NTFS)." }
elseif ($ramGB -ge 8) { Write-Result WARN "$ramGB GB RAM - meets the 8 GB minimum, 16 GB recommended." }
else { Write-Result FAIL "$ramGB GB RAM is below the 8 GB minimum." }

# --- 2. Machine-wide Dev Drive policy ---------------------------------------
Write-Host "`n-- Machine policy (fsutil devdrv query)" -ForegroundColor Cyan
$policy = & fsutil devdrv query 2>&1 | Out-String
if ($policy -match 'are enabled') {
    Write-Result PASS 'Developer volumes are enabled.'
} elseif ($policy -match 'are disabled') {
    Write-Result FAIL 'Developer volumes are DISABLED (group policy or temporary enterprise feature control).' `
        'Enable via Group Policy: Computer Configuration > Administrative Templates > System > Filesystem > Enable dev drive.'
} else {
    Write-Result INFO $policy.Trim()
}
if ($policy -match 'protected by antivirus filter') {
    Write-Result PASS 'Dev Drives are protected by an antivirus filter.'
} else {
    Write-Result WARN 'No antivirus filter attached to Dev Drives (/disallowAv may be set) - this is a real security risk.' `
        'Re-attach antivirus protection: fsutil devdrv enable /allowAv'
}
$policy -split "`r?`n" | Where-Object { $_ -match 'Filters allowed' } |
    ForEach-Object { Write-Result INFO $_.Trim() }

# --- 3. Per-volume checks ----------------------------------------------------
Write-Host "`n-- Volumes" -ForegroundColor Cyan
$volumes = Get-Volume | Where-Object { $_.DriveLetter }
if ($DriveLetter) { $volumes = $volumes | Where-Object { $_.DriveLetter -eq $DriveLetter.ToUpper() } }

$devDrives = @()
foreach ($v in $volumes) {
    $letter = "$($v.DriveLetter):"
    $sizeGB = [math]::Round($v.Size / 1GB, 1)
    $freeGB = [math]::Round($v.SizeRemaining / 1GB, 1)

    if ($v.FileSystemType -ne 'ReFS') {
        Write-Result INFO "$letter $($v.FileSystemType), $sizeGB GB - not a Dev Drive."
        continue
    }

    $q = & fsutil devdrv query $letter 2>&1 | Out-String
    $devDrives += $v
    if ($q -match 'not a trusted') {
        Write-Result WARN "$letter ReFS Dev Drive but UNTRUSTED - Defender scans it synchronously, no performance gain." `
            "Mark it trusted (elevated): fsutil devdrv trust $letter"
    } elseif ($q -match 'is a trusted') {
        Write-Result PASS "$letter trusted Dev Drive - $freeGB GB free of $sizeGB GB."
    } else {
        $hint = if ($elevated) { '' } else { ' (needs elevation)' }
        Write-Result INFO "$letter ReFS volume, trust state unknown$hint."
    }

    if ($freeGB -lt 20) {
        Write-Result WARN "$letter only $freeGB GB free - package caches and build output grow fast."
    }
    $attached = ($q -split "`r?`n" | Where-Object { $_ -match '^\s{2,}\S' } | ForEach-Object { $_.Trim() }) -join ', '
    if ($attached) { Write-Result INFO "$letter filters attached: $attached" }
}

if (-not $devDrives) {
    Write-Result WARN 'No Dev Drive (ReFS volume) found on this machine.' `
        'Create one: scripts/New-DevDriveVhdx.ps1 -VhdxPath C:\DevDrives\dev.vhdx -SizeGB 100 -DriveLetter E'
}
$devLetters = @($devDrives | ForEach-Object { "$($_.DriveLetter):" })

# --- 4. Defender performance mode -------------------------------------------
Write-Host "`n-- Microsoft Defender" -ForegroundColor Cyan
try {
    $pref = Get-MpPreference -ErrorAction Stop
    $status = Get-MpComputerStatus -ErrorAction Stop

    if ($status.AMRunningMode -and $status.AMRunningMode -notmatch 'Normal') {
        Write-Result WARN "Defender running mode is '$($status.AMRunningMode)' - performance mode only applies when Defender is the primary antivirus."
    }
    if ($status.RealTimeProtectionEnabled) {
        Write-Result PASS 'Real-time protection is on (required for performance mode).'
    } else {
        Write-Result FAIL 'Real-time protection is OFF - performance mode cannot run.' `
            'Turn real-time protection back on in Windows Security.'
    }

    # Get-MpPreference: 1 = Enabled, 0 = Disabled. This is INVERTED relative to the
    # Defender CSP ./Device/Vendor/MSFT/Defender/Configuration/PerformanceModeStatus,
    # where 0 = enable. Verified empirically: Set-MpPreference -PerformanceModeStatus
    # Disabled yields 0, Enabled yields 1.
    switch ([int]$pref.PerformanceModeStatus) {
        1 { Write-Result PASS 'PerformanceModeStatus = 1 (Enabled) - Dev Drive scans run asynchronously.' }
        0 { Write-Result WARN 'PerformanceModeStatus = 0 (Disabled) - Dev Drive gets synchronous real-time scans.' `
                'Enable performance mode (elevated): Set-MpPreference -PerformanceModeStatus Enabled' }
        default { Write-Result INFO "PerformanceModeStatus = $($pref.PerformanceModeStatus)." }
    }
    Write-Result INFO 'Ground truth: Windows Security > Virus & threat protection > Manage settings > Dev Drive protection > See volumes.'

    if ($status.AMProductVersion) {
        if ([version]$status.AMProductVersion -ge [version]'4.18.2303.8') {
            Write-Result PASS "Antimalware platform $($status.AMProductVersion) (>= 4.18.2303.8)."
        } else {
            Write-Result FAIL "Antimalware platform $($status.AMProductVersion) is below 4.18.2303.8." `
                'Update Defender: Update-MpSignature, or run Windows Update.'
        }
    }

    # Folder exclusions overlapping a Dev Drive defeat performance mode: an exclusion
    # blocks scanning altogether, performance mode only defers it. Performance mode wins.
    $overlap = @()
    foreach ($p in @($pref.ExclusionPath)) {
        foreach ($d in $devLetters) {
            $root = $d.TrimEnd(':')
            if ($p -match "^$([regex]::Escape($root))(:|\\|$)") { $overlap += $p; break }
        }
    }
    if ($overlap.Count) {
        $cmds = ($overlap | ForEach-Object { "Remove-MpPreference -ExclusionPath '$_'" }) -join '; '
        Write-Result WARN ("Defender path exclusions overlap a Dev Drive: {0}" -f ($overlap -join ', ')) `
            "Drop the redundant exclusions and let performance mode do the work (elevated): $cmds"
        Write-Result INFO 'An exclusion blocks scans entirely; performance mode defers them. Performance mode is the better trade on a Dev Drive.'
    } else {
        Write-Result PASS 'No Defender path exclusions overlap a Dev Drive.'
    }
} catch {
    Write-Result INFO "Could not read Defender state: $($_.Exception.Message)"
}

# --- 5. Package cache redirects ---------------------------------------------
Write-Host "`n-- Package caches" -ForegroundColor Cyan
$caches = [ordered]@{
    'NUGET_PACKAGES'             = 'NuGet global-packages (dotnet / MSBuild / VS)'
    'npm_config_cache'           = 'npm'
    'PIP_CACHE_DIR'              = 'pip'
    'CARGO_HOME'                 = 'Cargo (Rust)'
    'VCPKG_DEFAULT_BINARY_CACHE' = 'vcpkg binary cache'
    'GRADLE_USER_HOME'           = 'Gradle'
    'MAVEN_OPTS'                 = 'Maven (-Dmaven.repo.local=...)'
}
foreach ($name in $caches.Keys) {
    $user = [Environment]::GetEnvironmentVariable($name, 'User')
    $machine = [Environment]::GetEnvironmentVariable($name, 'Machine')
    $value = if ($user) { $user } else { $machine }
    if (-not $value) {
        Write-Result INFO "$name not set - $($caches[$name]) still uses its default location on C:."
        continue
    }
    $onDev = $false
    foreach ($d in $devLetters) {
        if ($value -match [regex]::Escape($d)) { $onDev = $true; break }
    }
    if ($onDev) { Write-Result PASS "$name -> $value" }
    else { Write-Result WARN "$name -> $value (not on a Dev Drive)." }
}

$tempUser = [Environment]::GetEnvironmentVariable('TEMP', 'User')
$tempOnDev = $false
foreach ($d in $devLetters) { if ($tempUser -match "^$([regex]::Escape($d))") { $tempOnDev = $true; break } }
if ($tempOnDev) {
    if ($policy -match 'WinSetupMon') { Write-Result PASS "TEMP -> $tempUser with WinSetupMon allowed." }
    else {
        Write-Result WARN "TEMP -> $tempUser but WinSetupMon is not allowed - the Windows Update process needs it." `
            'Allow it (elevated): fsutil devdrv setfiltersallowed "WdFilter, WinSetupMon"'
    }
} else {
    Write-Result INFO "TEMP -> $tempUser. Redirecting TEMP to a Dev Drive is optional and has side effects."
}

# --- Summary -----------------------------------------------------------------
Write-Host "`n=== Suggested fixes ===" -ForegroundColor Cyan
if ($script:Fixes.Count -eq 0) {
    Write-Host '  Nothing to do - configuration looks optimal.' -ForegroundColor Green
} else {
    $i = 1
    foreach ($f in $script:Fixes) { Write-Host ("  {0}. {1}" -f $i++, $f) -ForegroundColor Yellow }
}
Write-Host ''
