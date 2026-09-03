<#
.SYNOPSIS
    Starts a Chrome instance with a fixed DevTools port for agent-browser to
    attach to with --cdp, so agent-browser never has to launch a browser itself.

.DESCRIPTION
    agent-browser's own auto-launch cannot work from an elevated shell. Chrome
    refuses to run elevated on Windows: it relaunches itself de-elevated and the
    original process exits 0, so agent-browser sees "exited 0, no
    DevToolsActivePort", calls it a crash, and leaks the browser that actually
    came up. That repeats on every command.

    Pre-launching sidesteps the whole handshake. The de-elevation relaunch still
    happens, but it is Chrome's business now: the DevTools endpoint binds on
    localhost and is reachable whatever integrity level the browser ended up at.

    For that reason this script does NOT trust the process handle Start-Process
    returns — under de-elevation that process is gone within milliseconds and the
    real browser has a different pid. Readiness is decided by polling the
    endpoint, which is the only reliable signal.

    Idempotent: if the port already answers, the existing browser is reused and
    nothing is launched. Never requires admin.

.PARAMETER Port
    DevTools debugging port. Default 9222.

.PARAMETER ProfilePath
    Chrome user-data-dir. Default %LOCALAPPDATA%\agent-browser-cdp-profile.
    Kept out of %TEMP% deliberately: the cleanup script deletes stale
    agent-browser-chrome-* directories there.

.PARAMETER Headed
    Launch with a visible window instead of --headless=new.

.PARAMETER TimeoutSeconds
    How long to wait for the endpoint. Default 30.

.PARAMETER Force
    Stop a browser already using this profile, then launch a fresh one. Use when
    the port does not answer but the profile is locked.

.PARAMETER Stop
    Stop the browser using this profile and exit. Matches on the profile path, so
    the user's real Chrome is never touched.

.EXAMPLE
    .\Start-AgentBrowserCdp.ps1
    agent-browser --cdp 9222 open example.com  >out.log 2>&1 </dev/null

.EXAMPLE
    .\Start-AgentBrowserCdp.ps1 -Headed -Port 9333

.EXAMPLE
    .\Start-AgentBrowserCdp.ps1 -Stop
#>

[CmdletBinding()]
param(
    [int]$Port = 9222,
    [string]$ProfilePath = (Join-Path $env:LOCALAPPDATA 'agent-browser-cdp-profile'),
    [switch]$Headed,
    [int]$TimeoutSeconds = 30,
    [switch]$Force,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'

# Invoke-WebRequest is avoided here: on 5.1 it needs -UseBasicParsing and both
# editions can stall on proxy autodetection for a localhost call. A raw request
# with Proxy disabled is predictable on both.
function Get-CdpVersion {
    param([int]$Port)
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/json/version")
        $req.Proxy = $null
        $req.Timeout = 2000
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $reader.ReadToEnd()
        $reader.Close(); $resp.Close()
        return ($body | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# Match on the profile path, never on process name: a bare chrome match would
# also hit the user's real browser.
function Get-ProfileChrome {
    param([string]$ProfilePath)
    $needle = '--user-data-dir="{0}"' -f $ProfilePath
    $bare   = '--user-data-dir={0}'   -f $ProfilePath
    @(
        Get-CimInstance Win32_Process -Filter "Name LIKE '%chrome%'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                ($_.CommandLine.Contains($needle) -or $_.CommandLine.Contains($bare))
            }
    )
}

function Stop-ProfileChrome {
    param([string]$ProfilePath)
    $procs = Get-ProfileChrome -ProfilePath $ProfilePath
    if ($procs.Count -eq 0) { return 0 }
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    # Children reparent as their roots die, so one pass leaves stragglers.
    foreach ($p in $procs) {
        if (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    return $procs.Count
}

if ($Stop) {
    $n = Stop-ProfileChrome -ProfilePath $ProfilePath
    Write-Host ""
    if ($n -eq 0) { Write-Host "No browser was using $ProfilePath" }
    else          { Write-Host ("Stopped {0} process(es) using {1}" -f $n, $ProfilePath) }
    Write-Host ""
    return
}

Write-Host ""
Write-Host "=== agent-browser CDP browser ==="

$existing = Get-CdpVersion -Port $Port
if ($existing -and -not $Force) {
    Write-Host ("  reusing  : {0} already on port {1}" -f $existing.Browser, $Port)
    Write-Host ""
    Write-Host "Ready. Use --cdp on every call, and never pipe the output:"
    Write-Host ("  agent-browser --cdp {0} open <url>  >out.log 2>&1 </dev/null" -f $Port)
    Write-Host ""
    return
}

if ($Force) {
    $killed = Stop-ProfileChrome -ProfilePath $ProfilePath
    if ($killed -gt 0) { Write-Host ("  stopped  : {0} process(es) on the existing profile" -f $killed) }
}

# Newest agent-browser-managed Chrome first; then puppeteer's cache, which
# agent-browser also falls back to; then a system install.
$candidates = @(
    Get-ChildItem (Join-Path $env:USERPROFILE '.agent-browser\browsers\*\chrome.exe') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    Get-ChildItem (Join-Path $env:USERPROFILE '.cache\puppeteer\chrome\*\*\chrome.exe') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    Get-Item "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" -ErrorAction SilentlyContinue
    Get-Item "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe" -ErrorAction SilentlyContinue
)
$exe = $candidates | Select-Object -First 1
if (-not $exe) {
    Write-Host "  FAILED   : no chrome.exe found"
    Write-Host "             run 'agent-browser install', or install Chrome"
    Write-Host ""
    exit 1
}
Write-Host ("  chrome   : {0}" -f $exe.FullName)

New-Item -ItemType Directory -Force $ProfilePath | Out-Null
Write-Host ("  profile  : {0}" -f $ProfilePath)

$chromeArgs = @(
    "--remote-debugging-port=$Port"
    "--user-data-dir=`"$ProfilePath`""
    '--no-first-run'
    '--no-default-browser-check'
    '--disable-background-networking'
    '--disable-features=Translate'
    'about:blank'
)
if (-not $Headed) { $chromeArgs = @('--headless=new') + $chromeArgs }

$sw = [Diagnostics.Stopwatch]::StartNew()
Start-Process $exe.FullName -ArgumentList $chromeArgs -WindowStyle Hidden | Out-Null

# Poll the endpoint, not the process: see the de-elevation note in the header.
$version = $null
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds -and -not $version) {
    Start-Sleep -Milliseconds 200
    $version = Get-CdpVersion -Port $Port
}

if (-not $version) {
    Write-Host ("  FAILED   : port {0} did not answer within {1}s" -f $Port, $TimeoutSeconds)
    $stuck = Get-ProfileChrome -ProfilePath $ProfilePath
    if ($stuck.Count -gt 0) {
        Write-Host ("             {0} chrome process(es) hold this profile - retry with -Force" -f $stuck.Count)
    } else {
        Write-Host "             nothing is holding the profile; try -Headed to see Chrome's own error"
    }
    Write-Host ""
    exit 1
}

Write-Host ("  started  : {0} on port {1} in {2}s" -f `
    $version.Browser, $Port, [math]::Round($sw.Elapsed.TotalSeconds, 2))
Write-Host ""
Write-Host "Ready. Use --cdp on every call, and never pipe the output:"
Write-Host ("  agent-browser --cdp {0} open <url>  >out.log 2>&1 </dev/null" -f $Port)
Write-Host ""
Write-Host ("Stop it with: .\Start-AgentBrowserCdp.ps1 -Stop{0}" -f `
    $(if ($Port -ne 9222) { " -Port $Port" } else { "" }))
Write-Host ""
