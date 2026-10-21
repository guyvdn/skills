<#
.SYNOPSIS
    Applies the voidtools Everything fixes that Test-EverythingIndex.ps1 reports.
.DESCRIPTION
    Closes the Everything client (the service keeps running), backs up Everything.ini next to
    itself, then:
      - turns Match Path off (unless -KeepMatchPath),
      - adds node_modules, .git, bin, obj and $RECYCLE.BIN folder filters plus every package
        cache it finds to the exclude list - merged with what is already there,
      - stops indexing subst drives whose files a whole-volume entry already indexes
        (unless -KeepDuplicateVolumes). They are set to not-indexed rather than removed,
        because Everything re-adds a removed fixed drive on its own.
    It then restarts Everything, waits for the rebuild to settle, makes it save the database
    and reports the size before and after. Run it as the logged-on user, not elevated.
    Supports -WhatIf. Everything is left running at the end, also when a step fails.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Set-EverythingTuning.ps1 -WhatIf
.EXAMPLE
    # -File passes a list as one string; the script splits on commas
    powershell -ExecutionPolicy Bypass -File scripts/Set-EverythingTuning.ps1 -SkipFilter "*\bin,*\obj"
.EXAMPLE
    # Edit a copy only, no process control - for testing
    powershell -ExecutionPolicy Bypass -File scripts/Set-EverythingTuning.ps1 -IniPath C:\temp\Everything.ini -NoRestart
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
    [string[]]$ExtraExclude = @(),
    [string[]]$SkipFilter = @(),
    [switch]$KeepMatchPath,
    [switch]$KeepDuplicateVolumes,
    [string]$IniPath,
    [switch]$NoRestart,
    # With UAC off, or as the built-in Administrator, every token is elevated
    [switch]$AllowElevated
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'EverythingIni.ps1')

function Split-ListArgument {
    <# powershell -File hands "-SkipFilter '*\bin','*\obj'" over as ONE string, quotes included.
       Split on commas only when every piece looks like an entry of its own (a *\ filter or a
       drive path): a comma is legal in a folder name, as in "C:\Data\Smith, John". #>
    param([string[]]$Values)
    foreach ($v in $Values) {
        $pieces = @($v -split ',' | ForEach-Object { $_.Trim().Trim("'", '"') })
        $separate = @($pieces | Where-Object { $_ -match '^(\*|[A-Za-z]:\\)' }).Count -eq $pieces.Count
        $items = if ($separate) { $pieces } else { @($v.Trim().Trim("'", '"')) }
        $items | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ }
    }
}
$ExtraExclude = @(Split-ListArgument $ExtraExclude)
$SkipFilter = @(Split-ListArgument $SkipFilter)

function Get-PlannedChange {
    <# Works out every change from the ini as it is now. Called again after Everything has
       exited, because exiting rewrites the file and can reorder the volume lists. #>
    param($Ini)
    $current = @(ConvertFrom-IniList (Get-IniValue $Ini 'exclude_folders'))
    $filters = @($script:DefaultExcludeFilters | Where-Object { $SkipFilter -notcontains $_ }) + $ExtraExclude
    $caches = @(Get-PackageCacheFolders | Where-Object { -not (Test-PathExcluded $_ (@($current) + $filters)) })
    [pscustomobject]@{
        MatchPath  = -not $KeepMatchPath -and (Get-IniValue $Ini 'match_path') -eq '1'
        EnableList = (Get-IniValue $Ini 'exclude_list_enabled') -eq '0'
        Current    = $current
        Added      = @(@($filters) + $caches | Where-Object { $_ -and $current -notcontains $_ } | Select-Object -Unique)
        Redundant  = if ($KeepDuplicateVolumes) { @() } else { @(Get-RedundantVolumes @(Get-EverythingVolumes $Ini)) }
    }
}

function Wait-Client {
    param([bool]$Running, [int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ([bool](Get-EverythingClient) -ne $Running -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    [bool](Get-EverythingClient) -eq $Running
}

# --- Preconditions -------------------------------------------------------------------------
$exe = Get-EverythingExe
$controlProcess = -not $NoRestart
if ($controlProcess) {
    if (-not $exe) { throw 'Everything.exe not found - pass -IniPath with -NoRestart to edit a file directly.' }
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin -and -not $AllowElevated) {
        throw 'Run this unelevated, as the user whose Everything this is: elevated, it would restart Everything elevated, and over-the-shoulder UAC would edit the admin account''s ini. If UAC is off or this is the built-in Administrator, pass -AllowElevated.'
    }
    $problem = Get-EverythingSupportProblem $exe
    if ($problem) { throw "Not changing anything: $problem." }
}
if (-not $IniPath) {
    if (-not $exe) { throw 'Everything.exe not found - pass -IniPath to edit a file directly.' }
    $IniPath = Get-EverythingIniPath $exe
}

# --- Show the plan -------------------------------------------------------------------------
function Format-PlannedChange {
    param($Plan)
    if ($Plan.MatchPath) { 'match_path: 1 -> 0' }
    if ($Plan.EnableList) { 'exclude_list_enabled: 0 -> 1' }
    $Plan.Added | ForEach-Object { "exclude folder: + $_" }
    $Plan.Redundant | ForEach-Object { "stop indexing $($_.Path) (already covered by $($_.CoveredBy))" }
}

$changes = @(Format-PlannedChange (Get-PlannedChange (Read-EverythingIni $IniPath)))
if (-not $changes) { Write-Host 'Nothing to change.' -ForegroundColor Green; return }
Write-Host 'Changes:' -ForegroundColor Cyan
$changes | ForEach-Object { Write-Host "  $_" }
if (-not $PSCmdlet.ShouldProcess($IniPath, 'close Everything, back up and edit the ini, restart')) { return }
if ((Get-Item -LiteralPath $IniPath).IsReadOnly) { throw "$IniPath is read-only - nothing was changed." }

# --- Close the client: an edit made while it runs is overwritten on exit ---------------------
$db = Get-EverythingDbPath $IniPath
$closed = $false
$started = $false
try {
    if ($controlProcess -and (Get-EverythingClient)) {
        & $exe -exit
        $closed = $true
        if (-not (Wait-Client -Running $false -Seconds 30)) {
            throw 'Everything did not exit within 30 s (is it running elevated?) - the ini was not changed.'
        }
    }
    $dbBefore = if (Test-Path -LiteralPath $db) { (Get-Item -LiteralPath $db).Length } else { 0 }

    # Re-read and re-plan: the client rewrote the file on exit
    $ini = Read-EverythingIni $IniPath
    $plan = Get-PlannedChange $ini
    $replanned = @(Format-PlannedChange $plan)
    if (Compare-Object $changes $replanned) {
        Write-Host 'Everything rewrote its settings on exit; the changes would now be:' -ForegroundColor Yellow
        $replanned | ForEach-Object { Write-Host "  $_" }
        throw 'Changes differ from the ones shown - nothing was written. Run the script again to review them.'
    }
    $backup = '{0}.bak-{1:yyyyMMdd-HHmmss}' -f $IniPath, (Get-Date)
    Copy-Item -LiteralPath $IniPath -Destination $backup -ErrorAction Stop

    if ($plan.MatchPath) { Set-IniValue $ini 'match_path' '0' }
    Set-IniValue $ini 'exclude_list_enabled' '1'
    if ($plan.Added) { Set-IniValue $ini 'exclude_folders' (ConvertTo-IniList (@($plan.Current) + $plan.Added) -Quoted) }
    foreach ($kind in 'ntfs', 'refs') {
        $hits = @($plan.Redundant | Where-Object Kind -eq $kind)
        if (-not $hits) { continue }
        foreach ($key in "${kind}_volume_includes", "${kind}_volume_monitors") {
            $vals = @(ConvertFrom-IniList (Get-IniValue $ini $key))
            foreach ($h in $hits) { if ($h.Index -lt $vals.Count) { $vals[$h.Index] = '0' } }
            Set-IniValue $ini $key (ConvertTo-IniList $vals)
        }
    }
    Write-EverythingIni $ini
    Write-Host "Saved $IniPath  (backup: $backup)" -ForegroundColor Green
    if (-not $controlProcess) { return }

    # --- Restart, let the rebuild settle, then make it save the database ---------------------
    Start-Process $exe -ArgumentList '-startup'
    $started = $true
    if (-not (Wait-Client -Running $true -Seconds 30)) { throw 'Everything did not start again within 30 s.' }
    Write-Host 'Everything restarted - waiting for the index rebuild to settle...'
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 5
        $p = Get-EverythingClient | Select-Object -First 1
        if (-not $p) { break }
        $t0 = $p.TotalProcessorTime; Start-Sleep -Seconds 5; $p.Refresh()
        $busy = ($p.TotalProcessorTime - $t0).TotalSeconds -gt 0.5
    } while ($busy -and (Get-Date) -lt $deadline)

    & $exe -exit
    if (-not (Wait-Client -Running $false -Seconds 60)) {
        Write-Warning 'Everything did not exit to save its database - size not measured.'
        return
    }
    $dbAfter = if (Test-Path -LiteralPath $db) { (Get-Item -LiteralPath $db).Length } else { 0 }
    Write-Host ('Database: {0:N0} MB -> {1:N0} MB' -f ($dbBefore / 1MB), ($dbAfter / 1MB)) -ForegroundColor Cyan
    if ($dbBefore -and $dbAfter -ge $dbBefore * 0.95) {
        Write-Warning 'The database barely shrank. Check Tools > Options > Exclude that the filters show up, and re-run Test-EverythingIndex.ps1.'
    }
} finally {
    # Whatever happened above - including the deliberate exit that saves the database - leave
    # Everything running if this script closed or started it
    if (($closed -or $started) -and $exe -and -not (Get-EverythingClient)) { Start-Process $exe -ArgumentList '-startup' }
}
