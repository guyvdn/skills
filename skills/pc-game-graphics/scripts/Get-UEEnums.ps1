<#
.SYNOPSIS
    List the values of an Unreal Engine game's enums (EUpscaler::DLSS, ...) from
    its shipping exe, so you know which names a config key accepts.

.DESCRIPTION
    UE reflection keeps every UENUM value as an ASCII string "EName::Value" in the
    exe, and the strings of one enum sit next to each other. That gives the exact
    set of valid NAMES, which is what most game ini keys store (Upscaler=DLSS).

    The byte ORDER is only a hint at the numeric value: some enums are emitted
    in declaration order, others reversed (UE's own EDynamicGlobalIlluminationMethod
    is None,Lumen,ScreenSpace,Plugin in source but Plugin..None in the exe). The
    script prints the order as found and warns when a None/Off value sits last
    (likely reversed). Confirm any numeric key in the game's menu after editing.

    Read-only. Reads the whole exe into memory (150-300 MB is normal).

.PARAMETER Exe
    The <Project>-Win64-Shipping.exe (Find-GameConfig.ps1 prints it).

.PARAMETER Pattern
    Regex matched against the enum type name, e.g. 'Upscaler|GlobalIllumination|AntiAliasing'.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Get-UEEnums.ps1 -Exe '...\ES2-Win64-Shipping.exe' -Pattern 'Upscaler|GlobalIllum'
#>
param(
    [Parameter(Mandatory)][string]$Exe,
    [string]$Pattern = 'Upscaler|QualityMode|FrameGen|RayReconstruction|GlobalIllumination|AntiAliasing|Reflection|Shadow|Latency|WindowMode|Fullscreen'
)

$bytes = [IO.File]::ReadAllBytes((Resolve-Path $Exe))
$text = [Text.Encoding]::GetEncoding(28591).GetString($bytes)   # Latin-1: 1 char = 1 byte, offsets stay true
$bytes = $null

$hits = [regex]::Matches($text, '\b(E[A-Z][A-Za-z0-9_]*)::([A-Za-z_][A-Za-z0-9_]*)') |
    Where-Object { $_.Groups[1].Value -match $Pattern } |
    ForEach-Object { [pscustomobject]@{ Enum = $_.Groups[1].Value; Value = $_.Groups[2].Value; Offset = $_.Index } }

foreach ($g in $hits | Group-Object Enum | Sort-Object Name) {
    # first occurrence of each value, in byte order
    $vals = $g.Group | Group-Object Value | ForEach-Object { $_.Group | Sort-Object Offset | Select-Object -First 1 } | Sort-Object Offset
    $start = $vals[0].Offset
    "$($g.Name)   (position in exe; see .DESCRIPTION before reading it as a number)"
    $i = 0
    foreach ($v in $vals) {
        $gap = $v.Offset - $start
        $flag = if ($gap -gt 4096) { "   <-- $gap bytes from the first value: order uncertain" } else { '' }
        if ($v.Value -match '^(MAX|Num|Count|Type)$|_MAX$') { "  -  $($v.Value)  (sentinel or namespace, not a choice)$flag"; continue }
        "  $i  $($v.Value)$flag"
        $i++
    }
    $real = $vals | Where-Object Value -notmatch '^(MAX|Num|Count|Type)$|_MAX$'
    if ($real.Count -gt 1 -and $real[-1].Value -match '^(None|Off|Disabled)$' -and $real[0].Value -notmatch '^(None|Off|Disabled)$') {
        "  !! '$($real[-1].Value)' is last: this enum is probably stored REVERSED; numbers above are likely backwards"
    }
}
if (-not $hits) { "no enum strings matched '$Pattern' -- not an Unreal game, or the names differ (try a broader -Pattern)" }
