<#
.SYNOPSIS
    Reports duplicate, stale and stuck Windows print queues, and any jobs trapped in them.
.DESCRIPTION
    Read-only - changes nothing. Groups queues that point at the same physical printer,
    picks the keeper and names the duplicate, reports jobs stranded on an offline queue,
    lists ports no queue uses any more, and shows whether Windows is managing the default
    printer. Needs no admin rights.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Test-PrinterQueues.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/Test-PrinterQueues.ps1 -Json
#>
#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Json)

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

function Get-PortKind {
    <# Classifies a port from its name and, where present, its Get-PrinterPort record.
       On a Standard TCP/IP Port, Protocol 1 = RAW (usually :9100) and 2 = LPR (:515) -
       but Get-PrinterPort surfaces the value map, so it reads back as "RAW"/"LPR" rather
       than the number. Match both, or every LPR queue is mis-reported as plain TCP/IP. #>
    param([string]$Name, $Port)
    if ($Name -match '^WSD-') { return 'WSD' }
    if ($Name -match '^(nul:|PORTPROMPT:|FILE:|XPSPort:|SHRFAX:)' -or $Name -match '^Microsoft\.') { return 'Virtual' }
    if ($Name -match '^(LPT|COM)\d') { return 'Local' }
    if ($Port -and $Port.PrinterHostAddress) {
        switch -Regex ([string]$Port.Protocol) {
            '^(2|LPR)$' { return 'LPR' }
            '^(1|RAW)$' { return 'RAW' }
            default { return 'TCP/IP' }
        }
    }
    'Other'
}

function Get-ModelKey {
    <# Normalises a queue name to the physical model, so "Foo XY-100 series" and
       "Foo XY-100 series Printer" (the name WSD gives its own copy) collapse to one key. #>
    param([string]$Name)
    $k = $Name.ToLowerInvariant()
    $k = $k -replace '\(copy\s*\d+\)', ''
    $k = $k -replace '\s*\(\d+\)\s*$', ''
    $k = $k -replace '\b(series|printer|copy|class|driver|wsd)\b', ''
    $k -replace '[^a-z0-9]', ''
}

$ports = @{}
Get-PrinterPort -ErrorAction SilentlyContinue | ForEach-Object { $ports[$_.Name] = $_ }

$wmi = @{}
Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | ForEach-Object { $wmi[$_.Name] = $_ }

$rows = foreach ($p in (Get-Printer -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $kind = Get-PortKind -Name $p.PortName -Port $ports[$p.PortName]
    $jobs = try { @(Get-PrintJob -PrinterName $p.Name -ErrorAction Stop).Count } catch { -1 }
    # Generic in-box drivers print fine but expose none of the vendor's options - they are
    # the tell-tale of an auto-discovered duplicate rather than the queue the user installed.
    $generic = $p.DriverName -match 'Class Driver|IPP|WSD|Universal Print|Microsoft'
    [pscustomobject]@{
        Name     = $p.Name
        Port     = $p.PortName
        PortKind = $kind
        Driver   = $p.DriverName
        Generic  = [bool]$generic
        Status   = [string]$p.PrinterStatus
        Offline  = ([string]$p.PrinterStatus -match 'Offline|Error|NotAvailable') -or
                   [bool]$wmi[$p.Name].WorkOffline
        Jobs     = $jobs
        Physical = ($kind -ne 'Virtual' -and $kind -ne 'Other')
        ModelKey = Get-ModelKey $p.Name
        Default  = [bool]$wmi[$p.Name].Default
    }
}

function Get-KeeperScore {
    <# A queue is worth keeping when it is reachable, speaks the vendor driver, and sits on
       a real TCP/IP port. WSD scores down: it is what silently breaks and re-appears. #>
    param($r)
    $s = 0
    if (-not $r.Offline) { $s += 2 }
    if (-not $r.Generic) { $s += 2 }
    if ($r.PortKind -eq 'LPR' -or $r.PortKind -eq 'RAW' -or $r.PortKind -eq 'TCP/IP') { $s += 1 }
    if ($r.PortKind -eq 'WSD') { $s -= 2 }
    $s
}

$groups = $rows | Where-Object Physical | Group-Object ModelKey | Where-Object Count -gt 1
$orphans = @($ports.Keys | Where-Object { $_ -match '^WSD-' -and $rows.Port -notcontains $_ })
$legacy = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' `
        -Name LegacyDefaultPrinterMode -ErrorAction SilentlyContinue).LegacyDefaultPrinterMode

if ($Json) {
    [pscustomobject]@{
        Printers              = $rows
        DuplicateGroups       = @($groups | ForEach-Object { , @($_.Group.Name) })
        OrphanedPorts         = $orphans
        DefaultPrinter        = ($rows | Where-Object Default | Select-Object -First 1 -ExpandProperty Name)
        WindowsManagesDefault = ($legacy -ne 1)
    } | ConvertTo-Json -Depth 4
    return
}

function Format-Cell {
    # Virtual-printer ports and some driver names run to 90+ characters and push every
    # later column out of the table. Truncate rather than let Format-Table drop them.
    param([string]$Text, [int]$Max)
    if ($Text.Length -le $Max) { return $Text }
    $Text.Substring(0, $Max - 1) + [char]0x2026
}

Write-Host "`n=== Print queue audit ===" -ForegroundColor Cyan
$rows | Format-Table Name,
    @{ n = 'Port'; e = { Format-Cell $_.Port 26 } },
    @{ n = 'Kind'; e = { $_.PortKind } },
    Status, Jobs,
    @{ n = 'Driver'; e = { Format-Cell $_.Driver 30 } } -AutoSize |
    Out-String -Width 160 | Write-Host

# --- 1. Duplicate queues -----------------------------------------------------
Write-Host '-- Duplicate queues' -ForegroundColor Cyan
if (-not $groups) { Write-Result PASS 'No two queues point at the same physical printer.' }
foreach ($g in $groups) {
    $ranked = $g.Group | Sort-Object { Get-KeeperScore $_ } -Descending
    $keep = $ranked[0]
    Write-Result WARN ('{0} queues for one printer: {1}' -f $g.Count,
        (($g.Group.Name | ForEach-Object { '"{0}"' -f $_ }) -join ', '))
    Write-Result INFO ('Keeper: "{0}" - {1} port, {2} driver.' -f $keep.Name, $keep.PortKind,
        $(if ($keep.Generic) { 'in-box' } else { 'vendor' }))
    foreach ($dup in ($ranked | Select-Object -Skip 1)) {
        if ($dup.Jobs -gt 0) {
            Write-Result FAIL ('"{0}" holds {1} job(s) and is {2}.' -f $dup.Name, $dup.Jobs,
                $(if ($dup.Offline) { 'offline' } else { 'not the keeper' })) `
                ('Drain it first - Set-Printer -Name "{0}" -PortName "{1}" - then remove it once the queue empties.' -f $dup.Name, $keep.Port)
        } else {
            Write-Result WARN ('"{0}" is a duplicate with an empty queue.' -f $dup.Name) `
                ('Remove-Printer -Name "{0}"' -f $dup.Name)
        }
    }
}

# --- 2. Stranded jobs --------------------------------------------------------
Write-Host "`n-- Stranded jobs" -ForegroundColor Cyan
$stuck = @($rows | Where-Object { $_.Jobs -gt 0 -and $_.Offline })
if (-not $stuck) {
    Write-Result PASS 'No jobs waiting on an offline queue.'
} else {
    foreach ($s in $stuck) {
        Write-Result FAIL ('"{0}" is {1} with {2} job(s) queued.' -f $s.Name, $s.Status, $s.Jobs) `
            ('Repoint "{0}" at a live port for the same device, or cancel: Get-PrintJob -PrinterName "{0}" | Remove-PrintJob' -f $s.Name)
    }
}

# --- 3. Ports no queue uses --------------------------------------------------
Write-Host "`n-- Leftover ports" -ForegroundColor Cyan
if (-not $orphans) {
    Write-Result PASS 'No orphaned WSD ports.'
} else {
    foreach ($o in $orphans) {
        Write-Result WARN ('WSD port "{0}" belongs to no queue - it can re-create the duplicate.' -f $o) `
            ('Needs admin - Remove-PrinterPort -Name "{0}", or Print server properties > Ports.' -f $o)
    }
}

# --- 4. Default printer ------------------------------------------------------
Write-Host "`n-- Default printer" -ForegroundColor Cyan
$def = $rows | Where-Object Default | Select-Object -First 1
if ($def) { Write-Result INFO ('Default is "{0}".' -f $def.Name) }
else { Write-Result WARN 'No default printer is set.' }
if ($legacy -ne 1) {
    Write-Result WARN 'Windows manages the default - it follows the last printer used, and Settings hides the "Default" label.' `
        "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -Value 1"
} else {
    Write-Result PASS 'Default is pinned (LegacyDefaultPrinterMode = 1).'
}

# --- Summary -----------------------------------------------------------------
Write-Host "`n=== Suggested fixes ===" -ForegroundColor Cyan
if ($script:Fixes.Count -eq 0) {
    Write-Host '  Nothing to do.' -ForegroundColor Green
} else {
    $i = 1
    foreach ($f in ($script:Fixes | Select-Object -Unique)) { Write-Host ('  {0}. {1}' -f $i++, $f) }
}
Write-Host ''
