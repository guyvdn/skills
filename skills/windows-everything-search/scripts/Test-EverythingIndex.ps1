<#
.SYNOPSIS
    Audits voidtools Everything for the settings and index bloat that make search lag.
.DESCRIPTION
    Read-only - changes nothing, needs no admin. Reports the client's CPU and memory, the
    database size, Match Path / Regex, the exclude list, volumes indexed twice (subst
    drives), and package caches that are still indexed. -CountEntries also walks every
    indexed volume and counts the entries under node_modules/.git/bin/obj, which takes
    about 20 seconds per million files.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Test-EverythingIndex.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Test-EverythingIndex.ps1 -CountEntries
#>
#Requires -Version 5.1
[CmdletBinding()]
param([switch]$CountEntries)

. (Join-Path $PSScriptRoot 'EverythingIni.ps1')

function Write-Result {
    param([ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status, [string]$Message)
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    Write-Host ('  [{0}] {1}' -f $Status, $Message) -ForegroundColor $color
}

$exe = Get-EverythingExe
if (-not $exe) { Write-Result FAIL 'Everything.exe not found (not running, not in Program Files).'; exit 1 }
$iniPath = Get-EverythingIniPath $exe
$ini = Read-EverythingIni $iniPath
$version = (Get-Item $exe).VersionInfo.FileVersion

Write-Host "`nEverything $version" -ForegroundColor Cyan
Write-Result INFO "exe: $exe"
Write-Result INFO "ini: $iniPath"
$problem = Get-EverythingSupportProblem $exe
if ($problem) { Write-Result WARN "$problem - results below may not apply" }

# --- Process -------------------------------------------------------------------------------
$client = Get-EverythingClient | Select-Object -First 1
if ($client) {
    $up = (Get-Date) - $client.StartTime
    $cpuPerMin = $client.TotalProcessorTime.TotalSeconds / [math]::Max($up.TotalMinutes, 1)
    $ws = [int]($client.WorkingSet64 / 1MB)
    $msg = 'client: {0} MB working set, {1:N0} CPU-s in {2:N0} min ({3:N1} CPU-s/min)' -f $ws, $client.TotalProcessorTime.TotalSeconds, $up.TotalMinutes, $cpuPerMin
    Write-Result $(if ($cpuPerMin -gt 5 -or $ws -gt 400) { 'WARN' } else { 'PASS' }) $msg
} else {
    Write-Result INFO 'client not running - no CPU/memory reading'
}

$db = Get-EverythingDbPath $iniPath
if (Test-Path $db) {
    $item = Get-Item $db
    $mb = [int]($item.Length / 1MB)
    Write-Result $(if ($mb -gt 150) { 'WARN' } else { 'PASS' }) ('database: {0} MB, last saved {1:yyyy-MM-dd HH:mm}  ({2})' -f $mb, $item.LastWriteTime, $db)
}

# --- Search settings -----------------------------------------------------------------------
Write-Host "`nSearch settings" -ForegroundColor Cyan
if ((Get-IniValue $ini 'match_path') -eq '1') {
    Write-Result WARN 'Match Path is ON - every keystroke matches the full path of every object (Ctrl+U toggles it)'
} else { Write-Result PASS 'Match Path is off' }
if ((Get-IniValue $ini 'match_regex') -eq '1') {
    Write-Result WARN 'Regex is ON for every search - no fast filename lookup (Ctrl+R toggles it)'
}
if ((Get-IniValue $ini 'match_path_when_search_contains_path_separator') -ne '1') {
    Write-Result INFO 'match_path_when_search_contains_path_separator is off - typing \ will not switch to path matching'
}

# --- Exclusions ----------------------------------------------------------------------------
Write-Host "`nExclusions" -ForegroundColor Cyan
$excludeOn = (Get-IniValue $ini 'exclude_list_enabled') -ne '0'
$excludes = @(ConvertFrom-IniList (Get-IniValue $ini 'exclude_folders'))
if (-not $excludeOn) { Write-Result WARN 'exclude list is disabled (exclude_list_enabled=0)' }
$missing = $script:DefaultExcludeFilters | Where-Object { $excludes -notcontains $_ }
if ($missing) { Write-Result WARN ('not excluded: ' + ($missing -join ', ')) }
else { Write-Result PASS 'node_modules, .git, bin, obj and $RECYCLE.BIN are excluded' }

$caches = Get-PackageCacheFolders | Where-Object { -not (Test-PathExcluded $_ $excludes) }
foreach ($c in $caches) { Write-Result WARN "package cache still indexed: $c" }
if (-not $caches) { Write-Result PASS 'no indexed package caches found' }

# --- Volumes -------------------------------------------------------------------------------
Write-Host "`nVolumes" -ForegroundColor Cyan
$volumes = @(Get-EverythingVolumes $ini)
foreach ($v in $volumes) {
    $root = if ($v.Root) { " (root: $($v.Root))" } else { '' }
    $only = if ($v.IncludeOnly) { " (include only: $($v.IncludeOnly))" } else { '' }
    Write-Result INFO ('{0} {1}{2}{3} - {4}' -f $v.Kind.ToUpper(), $v.Path, $root, $only, $(if ($v.Included) { 'indexed' } else { 'not indexed' }))
}
if ($volumes | Where-Object { -not $_.Consistent }) {
    Write-Result WARN 'volume lists in the ini differ in length - Set-EverythingTuning.ps1 will not touch volumes'
}
foreach ($r in Get-RedundantVolumes $volumes) {
    Write-Result WARN ("{0} is a sub-folder of {1} on the same volume (a subst drive?) - indexed twice" -f $r.Path, $r.CoveredBy)
}
if ((Get-IniValue $ini 'folders')) { Write-Result INFO 'folder indexes configured (folders=...) - these are rescanned, not journal-monitored' }

# --- Entry counts --------------------------------------------------------------------------
if ($CountEntries -and -not ('IO.EnumerationOptions' -as [type])) {
    Write-Result INFO '-CountEntries needs PowerShell 7 (pwsh) for IO.EnumerationOptions'
} elseif ($CountEntries) {
    Write-Host "`nEntries per indexed volume (slow)" -ForegroundColor Cyan
    $opt = New-Object IO.EnumerationOptions
    $opt.RecurseSubdirectories = $true; $opt.IgnoreInaccessible = $true; $opt.AttributesToSkip = 0
    foreach ($v in $volumes | Where-Object Included) {
        # A subst drive letter already maps to its root folder, so start at the letter itself
        $start = $v.Path.TrimEnd('\') + '\'
        if (-not (Test-Path -LiteralPath $start)) { continue }
        $total = 0; $junk = 0
        foreach ($e in [IO.Directory]::EnumerateFileSystemEntries($start, '*', $opt)) {
            $total++
            if ($e -match '\\(node_modules|\.git|bin|obj|\$RECYCLE\.BIN)\\') { $junk++ }
        }
        Write-Result $(if ($junk -gt $total / 4) { 'WARN' } else { 'INFO' }) ('{0} {1:N0} entries, {2:N0} under node_modules/.git/bin/obj/$RECYCLE.BIN (counted on disk, before exclusions)' -f $start, $total, $junk)
    }
}
Write-Host ''
