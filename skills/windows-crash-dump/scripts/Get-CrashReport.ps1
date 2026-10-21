<#
.SYNOPSIS
    Summarize why Windows crashed: bugcheck events, dump files, hardware errors and recent
    updates, plus an optional !analyze -v of a crash dump.

.DESCRIPTION
    Read-only. The event-log part needs no admin. Dumps under C:\Windows are admin-only: copy one
    out first (see SKILL.md) and pass the copy with -DumpPath, or run this script elevated.

    Analysis uses cdb.exe from the WinDbg package (winget install Microsoft.WinDbg).

.PARAMETER Days
    How far back to look for crashes. Default 14.

.PARAMETER DumpPath
    A crash dump to analyze. Without it, only the event-log summary is printed.

.PARAMETER SymbolCache
    Local symbol cache. Default: %LOCALAPPDATA%\symbols.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Get-CrashReport.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Get-CrashReport.ps1 -DumpPath $env:TEMP\crash.dmp
#>
[CmdletBinding()]
param(
    [int]$Days = 14,
    [string]$DumpPath,
    [string]$SymbolCache = (Join-Path $env:LOCALAPPDATA 'symbols')
)

$since = (Get-Date).AddDays(-$Days)

function Get-Events([string]$Log, [hashtable]$Filter) {
    $Filter.LogName = $Log
    $Filter.StartTime = $since
    Get-WinEvent -FilterHashtable $Filter -ErrorAction SilentlyContinue
}

Write-Host "== Unexpected shutdowns since $($since.ToString('yyyy-MM-dd')) ==" -ForegroundColor Cyan
$kp41 = Get-Events System @{ ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 }
$bugchecks = Get-Events System @{ ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 }
$unexpected = Get-Events System @{ ProviderName = 'EventLog'; Id = 6008 }

if (-not ($kp41 -or $bugchecks)) { Write-Host 'None.' }
foreach ($e in $kp41) {
    # BugcheckCode 0 with no 1001 next to it = power loss, hard hang or forced power-off, not a BSOD.
    $code = ($e.Properties | Select-Object -First 1).Value
    Write-Host ("{0}  Kernel-Power 41  BugcheckCode=0x{1:X}" -f $e.TimeCreated, [int64]$code)
}
foreach ($e in $bugchecks) {
    $line = ($e.Message -split "`n" | Where-Object { $_ -match 'bugcheck was' }) -join ' '
    Write-Host ("{0}  {1}" -f $e.TimeCreated, $line.Trim())
}
foreach ($e in $unexpected) { Write-Host ("{0}  {1}" -f $e.TimeCreated, ($e.Message -split "`n")[0].Trim()) }

Write-Host "`n== Hardware errors (WHEA) ==" -ForegroundColor Cyan
$whea = Get-Events System @{ ProviderName = 'Microsoft-Windows-WHEA-Logger' }
if ($whea) { $whea | ForEach-Object { Write-Host ("{0}  Id {1}  {2}" -f $_.TimeCreated, $_.Id, ($_.Message -split "`n")[0].Trim()) } }
else { Write-Host 'None.' }

Write-Host "`n== Dump files ==" -ForegroundColor Cyan
# Listing works unelevated through cmd's dir; opening the files does not.
$dumps = cmd /c 'dir /o-d C:\Windows\MEMORY.DMP C:\Windows\Minidump\*.dmp 2>nul' |
    Where-Object { $_ -match '\.dmp|DMP$' }
if ($dumps) { $dumps | ForEach-Object { Write-Host $_.Trim() } } else { Write-Host 'None found.' }

Write-Host "`n== Updates installed since $($since.ToString('yyyy-MM-dd')) ==" -ForegroundColor Cyan
$updates = Get-Events Setup @{ Id = 2 } | Where-Object { $_.Message -match 'Installed state' }
if ($updates) { $updates | ForEach-Object { Write-Host ("{0}  {1}" -f $_.TimeCreated, ($_.Message -split "`n")[0].Trim()) } }
else { Write-Host 'None.' }

if (-not $DumpPath) { return }

Write-Host "`n== !analyze -v of $DumpPath ==" -ForegroundColor Cyan
try { [IO.File]::OpenRead($DumpPath).Close() }
catch { Write-Error "Cannot read $DumpPath - copy it out elevated first (see SKILL.md)."; exit 1 }

$pkg = Get-AppxPackage Microsoft.WinDbg
if (-not $pkg) { Write-Error 'WinDbg not installed: winget install Microsoft.WinDbg'; exit 1 }
$cdb = Join-Path $pkg.InstallLocation 'amd64\cdb.exe'

$sym = "srv*$SymbolCache*https://msdl.microsoft.com/download/symbols"
$out = & $cdb -z $DumpPath -y $sym -c '!analyze -v; q' 2>&1 | Out-String

$keys = 'BUGCHECK_CODE', 'BUGCHECK_P\d', 'PROCESS_NAME', 'SYMBOL_NAME', 'MODULE_NAME', 'IMAGE_NAME', 'FAILURE_BUCKET_ID'
foreach ($k in $keys) {
    [regex]::Matches($out, "(?m)^$k\s*:.*$") | ForEach-Object { Write-Host $_.Value.Trim() }
}

Write-Host "`nStack:"
$stack = [regex]::Match($out, '(?ms)^STACK_TEXT:\s*$(.*?)^\s*$').Groups[1].Value
$stack -split "`n" | Where-Object { $_ -match ' : (\S+)\s*$' } | ForEach-Object {
    Write-Host ('  ' + ($_ -replace '^.* : ', '').Trim())
}
