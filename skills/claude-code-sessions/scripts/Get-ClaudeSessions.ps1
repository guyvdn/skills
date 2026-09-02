<#
.SYNOPSIS
    Lists the Claude Code sessions running on this machine, with the friendly name,
    session id, working directory and pid of each.

.DESCRIPTION
    Claude Code writes one file per live session to <config>/sessions/<pid>.json. That
    file is the only place the session's friendly NAME (e.g. "webapp-f0") is
    mapped to its session id and working directory. Neither /status nor the status line
    reports the name, and an agent's own ListAgents shows names without ids - so this
    script is what joins the two.

    Why the name matters: cross-session messaging between Claude sessions is addressed by
    NAME, not by session id. Handing an agent a session UUID makes it go looking for a
    mapping it cannot see; handing it the name or the working directory is immediately
    actionable.

    LIVENESS: the files are keyed by pid and are not always cleaned up, so a crashed
    session can leave an entry behind. A pid on its own is not enough, because Windows
    reuses pids. This script matches the pid AND the process creation time recorded in
    the file's procStart field (a Windows FILETIME), so a reused pid is reported as stale
    rather than as a live session.

    Read-only. Never needs admin - these are the current user's own processes.

.PARAMETER Json
    Emit a JSON array on stdout instead of PowerShell objects. Use this when a script or
    an agent is consuming the output.

.PARAMETER IncludeStale
    Also list entries whose process is gone (crashed sessions that left a file behind).
    Stale rows are marked Alive = $false.

.PARAMETER Cwd
    Working directory to match when setting IsHere. Defaults to the current directory,
    which is only the session's own directory when the script is invoked from it - so an
    agent running this from elsewhere should pass its own working directory explicitly.

.PARAMETER ConfigDir
    Claude config directory to read. Defaults to $env:CLAUDE_CONFIG_DIR, or ~/.claude
    when that is unset. If you run more than one profile, each has its own
    session registry, so a session started under another profile will not appear
    unless you point this at it.

.EXAMPLE
    .\Get-ClaudeSessions.ps1
    Lists live sessions as a table.

.EXAMPLE
    .\Get-ClaudeSessions.ps1 -Json
    Structured output for an agent or a script.

.EXAMPLE
    .\Get-ClaudeSessions.ps1 -IncludeStale
    Includes crashed sessions that left a registry file behind.
#>
[CmdletBinding()]
param(
    [switch] $Json,
    [switch] $IncludeStale,
    [string] $Cwd,
    [string] $ConfigDir
)

$ErrorActionPreference = 'Stop'

if (-not $ConfigDir) {
    $ConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR }
                 else { Join-Path $HOME '.claude' }
}

$sessionsDir = Join-Path $ConfigDir 'sessions'
if (-not (Test-Path -LiteralPath $sessionsDir)) {
    Write-Error "No session registry at '$sessionsDir'. Check -ConfigDir, or the Claude Code version - this registry was not always written."
    exit 1
}

# Cache the process table once; one Get-Process beats one call per session file.
$procs = @{}
foreach ($p in Get-Process) {
    # StartTime throws for processes we cannot open. Those are not ours, so skip them.
    try { $procs[$p.Id] = $p.StartTime } catch { }
}

$here = if ($Cwd) { $Cwd } else { (Get-Location).Path }

$rows = foreach ($file in Get-ChildItem -LiteralPath $sessionsDir -Filter '*.json' -File) {
    try {
        $d = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Verbose "Skipping unreadable registry file '$($file.Name)': $($_.Exception.Message)"
        continue
    }

    if (-not $d.sessionId) { continue }

    # Liveness: the pid must exist AND have been created when the file says it was.
    # Without the second half, a reused pid reads as a live session.
    $alive = $false
    if ($d.pid -and $procs.ContainsKey([int]$d.pid)) {
        $alive = $true
        if ($d.procStart) {
            try {
                $expected = [DateTime]::FromFileTimeUtc([int64]$d.procStart)
                $actual = $procs[[int]$d.pid].ToUniversalTime()
                # Two seconds of slack: the file is written just after the process starts.
                if ([Math]::Abs(($actual - $expected).TotalSeconds) -gt 2) { $alive = $false }
            }
            catch {
                Write-Verbose "Could not compare procStart for pid $($d.pid): $($_.Exception.Message)"
            }
        }
    }

    [pscustomobject]@{
        Name      = $d.name
        SessionId = $d.sessionId
        Cwd       = $d.cwd
        Kind      = $d.kind
        Pid       = $d.pid
        Alive     = $alive
        IsHere    = ($d.cwd -and $here -and ($d.cwd.TrimEnd('\','/') -ieq $here.TrimEnd('\','/')))
        Started   = if ($d.startedAt) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$d.startedAt).LocalDateTime } else { $null }
        Version   = $d.version
    }
}

if (-not $IncludeStale) { $rows = $rows | Where-Object { $_.Alive } }
$rows = $rows | Sort-Object -Property @{Expression = 'Alive'; Descending = $true}, 'Name'

if ($Json) {
    # -Depth so nested nulls survive; -Compress off for readability in a transcript.
    if ($null -eq $rows) { '[]' }
    else { ,@($rows) | ConvertTo-Json -Depth 4 }
}
else {
    if ($null -eq $rows) {
        Write-Host 'No live Claude Code sessions found in this registry.'
    }
    else {
        $rows | Format-Table -AutoSize Name, SessionId, Cwd, Kind, Pid, Alive, IsHere
    }
}
