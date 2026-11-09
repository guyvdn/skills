<#
.SYNOPSIS
    Read-only audit before tuning a PC game's graphics: install folder, engine,
    upscaler DLLs, config file candidates, GPU and monitor.

.DESCRIPTION
    Changes nothing. Searches every Steam library (libraryfolders.vdf), Epic,
    GOG and Xbox folders for a directory matching -Name, then lists:
      - the shipping exe and a guess at the engine (Unreal / Unity / other)
      - upscaler and frame-generation DLLs with their versions
      - config files under the usual per-user locations
      - GPUs, monitor model and the modes the monitor's EDID lists
      - whether the game is running (it rewrites its config on exit)

.PARAMETER Name
    Part of the game's folder name, as a regex. E.g. 'Everspace', 'ES2'.
    Config folders often use a short code name (ES2), so pass both: 'Everspace|ES2'.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Find-GameConfig.ps1 -Name 'Everspace|ES2'
#>
param([Parameter(Mandatory)][string]$Name)

$ErrorActionPreference = 'SilentlyContinue'

function Section($t) { "`n=== $t ===" }

# --- install folders --------------------------------------------------------
$roots = @()
$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath
if ($steam) {
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    $roots += (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"').Matches |
        ForEach-Object { Join-Path ($_.Groups[1].Value -replace '\\\\', '\') 'steamapps\common' }
}
$roots += 'C:\Program Files\Epic Games', 'C:\Program Files (x86)\GOG Galaxy\Games', 'C:\GOG Games', 'C:\XboxGames'
$roots += Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root 'XboxGames'; Join-Path $_.Root 'Games' }

Section 'Install folders'
$installs = $roots | Select-Object -Unique | Where-Object { Test-Path $_ } |
    ForEach-Object { Get-ChildItem $_ -Directory | Where-Object Name -match $Name }
if (-not $installs) { "none found under: $(($roots | Select-Object -Unique) -join '; ')" }

foreach ($dir in $installs) {
    $dir.FullName
    $exes = Get-ChildItem $dir.FullName -Recurse -Filter *.exe |
        Where-Object { $_.Name -notmatch 'Crash|Redist|vc_?redist|UnrealCEFSubProcess|dxsetup|unins' }
    $shipping = $exes | Where-Object Name -match '-Win64-Shipping\.exe$'
    if ($shipping) {
        $uproj = $shipping.Directory.Parent.Parent.Name   # <Project>\Binaries\Win64
        "  engine : Unreal ($($shipping.Name), project folder '$uproj')"
        "  exe    : $($shipping.FullName)"
        if (Test-Path (Join-Path $dir.FullName 'Engine\Binaries\ThirdParty\Windows\WinPixEventRuntime')) { '  hint   : UE5-era third-party layout' }
    } elseif (Get-ChildItem $dir.FullName -Recurse -Filter UnityPlayer.dll | Select-Object -First 1) {
        '  engine : Unity (settings usually in HKCU:\Software\<Company>\<Product> or AppData\LocalLow)'
        $exes | Select-Object -First 3 | ForEach-Object { "  exe    : $($_.FullName)" }
    } else {
        '  engine : unknown'
        $exes | Sort-Object Length -Descending | Select-Object -First 3 | ForEach-Object { "  exe    : $($_.FullName)" }
    }

    "  upscaler / frame-gen DLLs:"
    $dlls = Get-ChildItem $dir.FullName -Recurse -File -Include nvngx_*.dll, sl.*.dll, libxess*.dll, *ffx*.dll, amd_fidelityfx*.dll
    if (-not $dlls) { '    (none: no DLSS/XeSS/FSR DLLs shipped)' }
    $dlls | ForEach-Object { '    {0,-42} {1}' -f $_.Name, $_.VersionInfo.FileVersion } | Sort-Object -Unique

    $proc = Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($dir.FullName) }
    if ($proc) { "  RUNNING: $($proc.Name -join ', ') -- close it before editing config files" }
}

# --- config candidates ------------------------------------------------------
Section 'Config candidates'
$docs = [Environment]::GetFolderPath('MyDocuments')
$cfgRoots = @(
    $env:LOCALAPPDATA, $env:APPDATA, (Join-Path $env:USERPROFILE 'AppData\LocalLow'),
    (Join-Path $docs 'My Games'), $docs, (Join-Path $env:USERPROFILE 'Saved Games')
)
$hits = foreach ($r in $cfgRoots) {
    if (Test-Path $r) { Get-ChildItem $r -Directory | Where-Object Name -match $Name }
    # Unity: LocalLow\<Company>\<Product>
    if ($r -like '*LocalLow') { Get-ChildItem $r -Directory | ForEach-Object { Get-ChildItem $_.FullName -Directory | Where-Object Name -match $Name } }
}
if (-not $hits) { 'none found by folder name; try the game''s short code name (UE project folder above) or look up the save path' }
foreach ($h in $hits) {
    Get-ChildItem $h.FullName -Recurse -File -Include *.ini, *.cfg, *.json, *.xml, *.txt, *.lua |
        Where-Object { $_.FullName -notmatch '\\(Logs|Crashes|SaveGames|CrashReportClient|webcache)\\' -and $_.Length -lt 2MB } |
        ForEach-Object { '{0}  ({1:N0} B, {2:yyyy-MM-dd HH:mm})' -f $_.FullName, $_.Length, $_.LastWriteTime }
}
$unity = Get-ChildItem HKCU:\Software -Recurse -Depth 1 | Where-Object PSChildName -match $Name
$unity | ForEach-Object { "registry: $($_.Name)" }

# --- hardware ---------------------------------------------------------------
Section 'GPUs'
Get-CimInstance Win32_VideoController | ForEach-Object {
    $mode = if ($_.CurrentHorizontalResolution) { "{0}x{1} @ {2} Hz" -f $_.CurrentHorizontalResolution, $_.CurrentVerticalResolution, $_.CurrentRefreshRate } else { 'no display attached' }
    '{0} (driver {1}) -- {2}' -f $_.Name, $_.DriverVersion, $mode
}

Section 'Monitors (EDID)'
$ids = Get-CimInstance -Namespace root\wmi WmiMonitorID
$modes = Get-CimInstance -Namespace root\wmi WmiMonitorListedSupportedSourceModes
foreach ($id in $ids) {
    $dec = { param($a) ($a | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join '' }
    $name = '{0} {1}' -f (& $dec $id.ManufacturerName), (& $dec $id.UserFriendlyName)
    $m = $modes | Where-Object InstanceName -eq $id.InstanceName
    $list = $m.MonitorSourceModes | ForEach-Object {
        [pscustomobject]@{ W = $_.HorizontalActivePixels; H = $_.VerticalActivePixels
            Hz = [math]::Round($_.VerticalRefreshRateNumerator / [math]::Max(1, $_.VerticalRefreshRateDenominator)) }
    } | Sort-Object { $_.W * $_.H }, Hz -Descending
    $top = $list | Select-Object -First 1
    "$name"
    if ($top) {
        $atNative = ($list | Where-Object { $_.W -eq $top.W -and $_.H -eq $top.H } | ForEach-Object Hz | Sort-Object -Unique -Descending) -join ', '
        $maxHz = ($list | Measure-Object Hz -Maximum).Maximum
        "  native $($top.W)x$($top.H), listed refresh at native: $atNative Hz; highest listed anywhere: $maxHz Hz"
    }
}
'Note: the EDID list is what this connection advertises. If the panel is rated higher than the'
'native-resolution refresh shown here, suspect the cable/port (often HDMI) before Windows settings.'
