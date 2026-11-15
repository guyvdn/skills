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

Section 'Displays'
# Connection type per monitor (WmiMonitorConnectionParams.VideoOutputTechnology)
$tech = @{ 0 = 'VGA'; 4 = 'DVI'; 5 = 'HDMI'; 10 = 'DisplayPort'; 11 = 'DisplayPort (embedded)'; 16 = 'virtual/indirect' }
$conn = @{}
Get-CimInstance -Namespace root\wmi WmiMonitorConnectionParams | ForEach-Object {
    $conn[$_.InstanceName] = if ($tech.ContainsKey([int]$_.VideoOutputTechnology)) { $tech[[int]$_.VideoOutputTechnology] } else { "type $($_.VideoOutputTechnology)" }
}
Get-CimInstance -Namespace root\wmi WmiMonitorID | ForEach-Object {
    $name = (($_.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join '')
    "monitor: $name, connected over $($conn[$_.InstanceName])"
}

# The modes Windows actually offers. Do NOT use WmiMonitorListedSupportedSourceModes for
# this: it lists only the EDID's base-block modes and misses high-refresh timings kept in
# extension blocks (a 100 Hz ultrawide on DisplayPort showed only 60 Hz there).
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class GcDisplayModes {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct DEVMODE { [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dmDeviceName; public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields; public int dmPositionX, dmPositionY; public int dmDisplayOrientation, dmDisplayFixedOutput; public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dmFormName; public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency, dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct DISPLAY_DEVICE { public int cb; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string DeviceName; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string DeviceString; public int StateFlags; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string DeviceID; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string DeviceKey; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplayDevices(string d, int i, ref DISPLAY_DEVICE dd, int f);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplaySettingsEx(string d, int i, ref DEVMODE m, int f);
  public static List<string> Get() { var r = new List<string>();
    for (int i = 0; ; i++) {
      var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(dd);
      if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
      if ((dd.StateFlags & 1) == 0) continue;   // not attached to the desktop
      var cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(cur); EnumDisplaySettingsEx(dd.DeviceName, -1, ref cur, 0);
      var hz = new SortedSet<int>();
      for (int j = 0; ; j++) { var m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(m); if (!EnumDisplaySettingsEx(dd.DeviceName, j, ref m, 0)) break;
        if (m.dmPelsWidth == cur.dmPelsWidth && m.dmPelsHeight == cur.dmPelsHeight) hz.Add(m.dmDisplayFrequency); }
      int max = 0; foreach (var h in hz) max = h;
      r.Add(string.Format("{0} on {1}: {2}x{3} @ {4} Hz now; offered at this resolution: {5} Hz{6}",
        dd.DeviceName, dd.DeviceString, cur.dmPelsWidth, cur.dmPelsHeight, cur.dmDisplayFrequency, string.Join(", ", hz),
        max > cur.dmDisplayFrequency + 1 ? "   <-- running below the highest offered rate" : ""));
    }
    return r; } }
'@
[GcDisplayModes]::Get()
"Hz shown as 59/60 is the same 59.94/60 Hz timing. If the panel's rated refresh isn't offered at"
"native resolution at all, then suspect the cable/port (HDMI version, DP 1.1 OSD setting)."
