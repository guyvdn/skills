<#
.SYNOPSIS
    Finds and removes orphaned agent-browser Chrome trees and the stale Chrome
    profile directories they leave in %TEMP%.

.DESCRIPTION
    agent-browser launches Chrome and waits for it to write DevToolsActivePort.
    When that wait times out, agent-browser reports "Chrome exited early" and
    retries — but the browser from the "failed" attempt is alive and no longer
    tracked by anything. Those browsers never exit on their own.

    OWNERSHIP: do not use "the parent process is dead" to detect these.
    agent-browser detaches every browser it launches, so a perfectly healthy
    tree also has a dead parent. What is reliable is the daemon: a browser can
    only belong to a daemon that already existed when the browser started. So a
    tree is an orphan when there is no live daemon at all, or when it predates
    the earliest live daemon. Trees started after a live daemon are left alone,
    because from outside the process table there is no way to tell which one
    that daemon actually holds.

    Never requires admin: these are user-owned processes.

.PARAMETER MinAgeMinutes
    Ignore browsers younger than this. Guards against reaping a launch that is
    still completing. Default 5.

.PARAMETER KeepTempProfiles
    Skip cleanup of stale %TEMP%\agent-browser-chrome-* profile directories.

.PARAMETER DryRun
    Report what would be removed; remove nothing.

.EXAMPLE
    .\Remove-OrphanedAgentBrowsers.ps1 -DryRun

.EXAMPLE
    .\Remove-OrphanedAgentBrowsers.ps1 -MinAgeMinutes 0
#>

[CmdletBinding()]
param(
    [int]$MinAgeMinutes = 5,
    [switch]$KeepTempProfiles,
    [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'
$now = Get-Date

# Match only browsers under the agent-browser cache. A bare name match would
# also hit the user's real Chrome, which must never be touched.
$browserRoot = Join-Path $env:USERPROFILE '.agent-browser'

$abChrome = @(
    Get-CimInstance Win32_Process -Filter "Name LIKE '%chrome%'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($browserRoot, 'OrdinalIgnoreCase') }
)
$daemons = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'agent-browser%'" | Where-Object CreationDate)

Write-Host ""
Write-Host "=== agent-browser state ==="
Write-Host ("  chrome processes : {0}" -f $abChrome.Count)
Write-Host ("  live daemons     : {0}" -f $daemons.Count)

# A browser cannot belong to a daemon that started after it.
$cutoff = if ($daemons.Count -eq 0) { $now }
          else { ($daemons | Sort-Object CreationDate | Select-Object -First 1).CreationDate }

$abPids = @($abChrome | ForEach-Object { [int]$_.ProcessId })
$roots  = @($abChrome | Where-Object { $abPids -notcontains [int]$_.ParentProcessId })

$orphanRoots = @(
    $roots | Where-Object {
        $_.CreationDate -and
        ($now - $_.CreationDate).TotalMinutes -ge $MinAgeMinutes -and
        $_.CreationDate -lt $cutoff
    }
)

if ($abChrome.Count -gt 0) {
    Write-Host ("  browser trees    : {0} ({1} orphaned)" -f $roots.Count, $orphanRoots.Count)
}

$doomed = @()
if ($orphanRoots.Count -gt 0) {
    $childrenOf = @{}
    foreach ($c in $abChrome) {
        $pp = [int]$c.ParentProcessId
        if (-not $childrenOf.ContainsKey($pp)) { $childrenOf[$pp] = @() }
        $childrenOf[$pp] += $c
    }

    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $orphanRoots) {
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push($root)
        while ($stack.Count -gt 0) {
            $cur = $stack.Pop()
            $list.Add($cur)
            foreach ($kid in $childrenOf[[int]$cur.ProcessId]) { $stack.Push($kid) }
        }
    }
    $doomed = @($list)

    $memMB = [int](($doomed | Measure-Object WorkingSetSize -Sum).Sum / 1MB)
    Write-Host ""
    Write-Host ("=== {0} {1} orphaned process(es) in {2} tree(s), {3} MB ===" -f `
        $(if ($DryRun) { 'Would remove' } else { 'Removing' }), $doomed.Count, $orphanRoots.Count, $memMB)

    if (-not $DryRun) {
        # Children reparent as their roots die, so one pass leaves stragglers.
        foreach ($d in $doomed) { Stop-Process -Id $d.ProcessId -Force }
        Start-Sleep -Milliseconds 500
        foreach ($d in $doomed) {
            if (Get-Process -Id $d.ProcessId) { Stop-Process -Id $d.ProcessId -Force }
        }

        # A daemon with no browsers left holds stale <session>.pid/.port files
        # that make the next `agent-browser close --all` report success on
        # nothing. It respawns on demand, so dropping it costs nothing.
        $stillAlive = @(
            Get-CimInstance Win32_Process -Filter "Name LIKE '%chrome%'" |
                Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($browserRoot, 'OrdinalIgnoreCase') }
        )
        if ($stillAlive.Count -eq 0) {
            foreach ($d in $daemons) {
                if (($now - $d.CreationDate).TotalMinutes -lt $MinAgeMinutes) { continue }
                Stop-Process -Id $d.ProcessId -Force
                if ($?) { Write-Host ("  removed stale daemon PID {0}" -f $d.ProcessId) }
            }
        }
    }
}

if (-not $KeepTempProfiles) {
    # Keep profile dirs belonging to browsers that are still running.
    $inUse = @(
        Get-CimInstance Win32_Process -Filter "Name LIKE '%chrome%'" |
            Where-Object { $_.CommandLine -match '--user-data-dir="?([^"\s]+)' } |
            ForEach-Object { if ($_.CommandLine -match '--user-data-dir="?([^"\s]+)') { $Matches[1] } }
    )

    $stale = @(
        Get-ChildItem (Join-Path $env:TEMP 'agent-browser-chrome-*') -Directory |
            Where-Object { $inUse -notcontains $_.FullName }
    )

    if ($stale.Count -gt 0) {
        $sz = 0
        foreach ($d in $stale) {
            $sz += (Get-ChildItem $d.FullName -Recurse -File | Measure-Object Length -Sum).Sum
        }
        Write-Host ""
        Write-Host ("=== {0} {1} stale profile dir(s), {2:N2} GB ===" -f `
            $(if ($DryRun) { 'Would remove' } else { 'Removing' }), $stale.Count, ($sz / 1GB))
        if (-not $DryRun) {
            foreach ($d in $stale) { Remove-Item $d.FullName -Recurse -Force }
        }
    }
}

Write-Host ""
Write-Host "=== Done ==="
if ($DryRun) { Write-Host "Dry run - nothing was changed." }
