<#
.SYNOPSIS
    Silently updates an app installed with a Qt Installer Framework (IFW) offline installer.

.DESCRIPTION
    For vendor apps that are not in winget/Chocolatey and whose maintenancetool.exe only knows
    a local repository. Asks the vendor's version endpoint for the latest version, compares it
    with the installed exe, downloads the installer into a cache, requires a valid Authenticode
    signature from the expected publisher, skips if the app is running, then purges the old
    version and installs the new one headlessly. If the version afterwards doesn't match, it
    reinstalls the previous cached installer. Every step is logged.

    Run elevated, in the user's session (a logon task with RunLevel Highest), so the
    installer's shortcuts land on that user's desktop and Start menu.

.PARAMETER AppDir
    Install folder (contains maintenancetool.exe).

.PARAMETER ExeName
    Main executable in AppDir; its ProductVersion is the installed version.

.PARAMETER LatestVersionUrl
    URL returning JSON with the latest version.

.PARAMETER VersionProperty
    Dotted path to the version in that JSON, e.g. data.latestVersion.

.PARAMETER InstallerUrl
    Installer URL with {0} where the version goes. URL-encode spaces as %20.

.PARAMETER SignerMatch
    Text the signer certificate's subject must contain. Pin something stable such as the
    company registration number (SERIALNUMBER=...) rather than the thumbprint, which changes
    with every certificate renewal.

.PARAMETER CacheDir
    Where installers and the log are kept. The current and previous installer stay (rollback).

.EXAMPLE
    .\Update-QtIfwApp.ps1 -AppDir 'C:\Program Files\Falcon Design Space' -ExeName FalconDesignSpace.exe `
        -LatestVersionUrl 'https://webapp.craftseek.com/pc-api/pcVersion/latestVersion' -VersionProperty data.latestVersion `
        -InstallerUrl 'https://download.craftseek.com/{0}/Windows/Falcon%20Design%20Space%20{0}.exe' `
        -SignerMatch 'SERIALNUMBER=91440300094231378E' -CacheDir C:\ProgramData\FalconUpdate
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppDir,
    [Parameter(Mandatory)][string]$ExeName,
    [Parameter(Mandatory)][string]$LatestVersionUrl,
    [string]$VersionProperty = 'latestVersion',
    [Parameter(Mandatory)][string]$InstallerUrl,
    [Parameter(Mandatory)][string]$SignerMatch,
    [Parameter(Mandatory)][string]$CacheDir
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest crawls with the progress bar in PowerShell 5.1

New-Item -ItemType Directory -Force $CacheDir | Out-Null
$log = Join-Path $CacheDir 'update.log'
$appName = Split-Path $AppDir -Leaf
$procName = [IO.Path]::GetFileNameWithoutExtension($ExeName)

function Log($msg) { '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg | Add-Content $log; Write-Output $msg }
function Get-Installed { $f = Get-Item (Join-Path $AppDir $ExeName) -ErrorAction SilentlyContinue; if ($f) { [version]$f.VersionInfo.ProductVersion } }
function Get-Cached {
    Get-ChildItem $CacheDir -Filter "$appName *.exe" |
        Sort-Object { [version]($_.BaseName.Substring($appName.Length + 1)) } -Descending
}

function Install-Version($installer) {
    $mt = Join-Path $AppDir 'maintenancetool.exe'
    # Qt IFW: options go BEFORE the command (after it they are read as package names), and
    # --accept-messages and --default-answer are mutually exclusive. Either mistake = exit 1.
    if (Test-Path $mt) {
        $p = Start-Process $mt '--confirm-command --accept-messages purge' -Wait -PassThru -WindowStyle Hidden
        Log "  purge exit $($p.ExitCode)"
    }
    $p = Start-Process $installer "--root `"$AppDir`" --accept-licenses --accept-obligations --accept-messages --confirm-command install" -Wait -PassThru -WindowStyle Hidden
    Log "  install exit $($p.ExitCode)"
}

try {
    $installed = Get-Installed
    $json = Invoke-RestMethod $LatestVersionUrl -TimeoutSec 30
    $value = $json
    foreach ($part in $VersionProperty.Split('.')) { $value = $value.$part }
    if (-not $value) { Log "ERROR: no '$VersionProperty' in the response from $LatestVersionUrl"; return }
    $latest = [version]$value
    if ($installed -and $latest -le $installed) { Log "up to date ($installed)"; return }

    $installer = Join-Path $CacheDir "$appName $latest.exe"
    if (-not (Test-Path $installer)) {
        Log "downloading $latest"
        Invoke-WebRequest ($InstallerUrl -f $latest) -OutFile "$installer.part" -UseBasicParsing -TimeoutSec 1800
        Move-Item "$installer.part" $installer -Force
    }
    $sig = Get-AuthenticodeSignature $installer
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike "*$SignerMatch*") {
        Log "REFUSED ${latest}: signature $($sig.Status), signer $($sig.SignerCertificate.Subject)"
        Remove-Item $installer -Force
        return
    }
    # Checked last, right before touching the install: never pull the app from under a running job.
    if (Get-Process $procName -ErrorAction SilentlyContinue) { Log "update $installed -> $latest ready, but $procName is running: next time"; return }

    Log "updating $installed -> $latest"
    Install-Version $installer
    $now = Get-Installed
    if ($now -eq $latest) {
        Log "OK, now $now"
        Get-Cached | Select-Object -Skip 2 | Remove-Item -Force    # keep this one and the previous one
    } else {
        Log "FAILED: installed version is now '$now'"
        $prev = Get-Cached | Where-Object { $_.FullName -ne $installer } | Select-Object -First 1
        if ($prev) { Log "rolling back with $($prev.Name)"; Install-Version $prev.FullName; Log "after rollback: $(Get-Installed)" }
    }
} catch {
    Log "ERROR: $($_.Exception.Message)"
}
