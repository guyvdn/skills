<#
.SYNOPSIS
    Creates a VHDX-backed Dev Drive: creates and attaches the virtual disk, formats it
    as a Dev Drive (ReFS), marks it trusted, and optionally sets the allowed filter list
    and a logon task that re-attaches the VHDX after reboot.
.DESCRIPTION
    Requires an elevated session. Uses diskpart to create/attach the vdisk (no Hyper-V
    module dependency) and Format-Volume -DevDrive to format it.

    Only creates NEW virtual disks. Formatting an existing volume as a Dev Drive destroys
    its contents and is deliberately not supported here - do that from Windows Settings
    (System > Storage > Advanced storage settings > Disks & volumes) where the destructive
    step is explicit.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/New-DevDriveVhdx.ps1 -VhdxPath C:\DevDrives\dev.vhdx -SizeGB 100 -DriveLetter E
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/New-DevDriveVhdx.ps1 -VhdxPath C:\Users\<user>\dev.vhdx -SizeGB 250 -DriveLetter E -Filters 'WdFilter, PrjFlt, bindFlt, wcifs' -RegisterAutoMount
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', PositionalBinding = $false)]
param(
    # Where the .vhdx file is created. Use a per-user path to avoid unintended sharing.
    [Parameter(Mandatory = $true)]
    [string]$VhdxPath,

    # Maximum size in GB. Dev Drive minimum is 50 GB.
    [Parameter(Mandatory = $true)]
    [ValidateRange(50, 65536)]
    [int]$SizeGB,

    # Drive letter to assign.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter,

    # Volume label.
    [string]$Label = 'Dev',

    # Fixed-size instead of dynamically expanding (allocates the full size up front).
    [switch]$Fixed,

    # Filter allow list applied machine-wide with fsutil devdrv setfiltersallowed.
    # NOTE: this replaces the existing list and applies to ALL Dev Drives on the machine.
    [string]$Filters,

    # Register a scheduled task that re-attaches the VHDX at logon.
    [switch]$RegisterAutoMount
)

$ErrorActionPreference = 'Stop'

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Elevated)) { throw 'This script needs an elevated PowerShell session.' }

$letter = $DriveLetter.ToUpper()
$drive = "${letter}:"

# --- Preflight ---------------------------------------------------------------
$os = [Environment]::OSVersion.Version
if (-not ($os.Build -gt 22621 -or ($os.Build -eq 22621 -and $os.Revision -ge 2338))) {
    throw "Windows build $($os.Build).$($os.Revision) is below the Dev Drive minimum 22621.2338."
}
if ((& fsutil devdrv query 2>&1 | Out-String) -match 'are disabled') {
    throw 'Developer volumes are disabled on this machine (group policy). Enable Dev Drive in Group Policy first.'
}
if ($letter -eq 'C') { throw 'C: cannot be a Dev Drive.' }
if (Test-Path $VhdxPath) { throw "$VhdxPath already exists. Pick another path or delete it first." }
if (Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue) {
    throw "Drive letter $drive is already in use."
}
if ([IO.Path]::GetExtension($VhdxPath) -ne '.vhdx') {
    Write-Warning 'VHDX is recommended over VHD (64 TB max, better resilience to IO failure).'
}

$parent = Split-Path -Parent $VhdxPath
if ($parent -and -not (Test-Path $parent)) {
    if ($PSCmdlet.ShouldProcess($parent, 'Create directory')) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}
$hostVol = Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($parent)[0]) -ErrorAction SilentlyContinue
if ($hostVol -and $Fixed -and $hostVol.SizeRemaining -lt ($SizeGB * 1GB)) {
    throw "Not enough free space on $($hostVol.DriveLetter): for a $SizeGB GB fixed VHDX."
}

$type = if ($Fixed) { 'fixed' } else { 'expandable' }
if (-not $PSCmdlet.ShouldProcess("$VhdxPath ($SizeGB GB, $type) -> $drive", 'Create Dev Drive')) { return }

# --- 1. Create + attach the virtual disk (diskpart) --------------------------
$script = @"
create vdisk file="$VhdxPath" maximum=$($SizeGB * 1024) type=$type
select vdisk file="$VhdxPath"
attach vdisk
convert gpt
create partition primary
assign letter=$letter
"@
$scriptFile = Join-Path $env:TEMP "devdrive-$([guid]::NewGuid().ToString('N')).txt"
Set-Content -LiteralPath $scriptFile -Value $script -Encoding ASCII
try {
    Write-Host "Creating $VhdxPath ($SizeGB GB, $type)..." -ForegroundColor Cyan
    $out = & diskpart /s $scriptFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "diskpart failed:`n$out" }
    Write-Verbose $out
} finally {
    Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
}

# diskpart returns before the volume is always visible to the storage stack.
$deadline = (Get-Date).AddSeconds(30)
do {
    $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $vol) { Start-Sleep -Milliseconds 500 }
} until ($vol -or (Get-Date) -gt $deadline)
if (-not $vol) { throw "Volume $drive did not appear after attaching the VHDX." }

# --- 2. Format as a Dev Drive ------------------------------------------------
Write-Host "Formatting $drive as a Dev Drive (ReFS)..." -ForegroundColor Cyan
Format-Volume -DriveLetter $letter -DevDrive -NewFileSystemLabel $Label -Confirm:$false | Out-Null

# --- 3. Trust ----------------------------------------------------------------
$q = & fsutil devdrv query $drive 2>&1 | Out-String
if ($q -notmatch 'is a trusted') {
    Write-Host "Marking $drive trusted..." -ForegroundColor Cyan
    & fsutil devdrv trust $drive | Out-Null
}

# --- 4. Filter allow list (machine-wide) ------------------------------------
if ($Filters) {
    if ($PSCmdlet.ShouldProcess("all Dev Drives on this machine", "Set allowed filters to '$Filters'")) {
        Write-Warning 'fsutil devdrv setfiltersallowed REPLACES the allow list for every Dev Drive on this machine.'
        & fsutil devdrv setfiltersallowed $Filters | Out-Null
    }
}

# --- 5. Auto-mount at logon --------------------------------------------------
if ($RegisterAutoMount) {
    $taskName = "Mount Dev Drive ($([IO.Path]::GetFileName($VhdxPath)))"
    $cmd = "Mount-DiskImage -ImagePath '$VhdxPath' -StorageType VHDX -NoDriveLetter:`$false"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -Command `"$cmd`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    if ($PSCmdlet.ShouldProcess($taskName, 'Register scheduled task')) {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "Registered logon task '$taskName'." -ForegroundColor Green
    }
}

# --- Report ------------------------------------------------------------------
Write-Host ''
Write-Host "Dev Drive ready at $drive" -ForegroundColor Green
& fsutil devdrv query $drive
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host "  1. Reboot once and confirm $drive comes back. If it does not, re-run with -RegisterAutoMount."
Write-Host "  2. Redirect package caches: scripts/Set-DevDriveCaches.ps1 -DriveLetter $letter -Move"
Write-Host "  3. Audit the result:        scripts/Test-DevDrive.ps1 -DriveLetter $letter"
Write-Host '  4. Do NOT add Defender folder exclusions for this drive - performance mode is the better trade.'
