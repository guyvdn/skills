<#
.SYNOPSIS
    Check every slide of an interactive reveal.js deck for content overflow
    and JavaScript errors.

.DESCRIPTION
    Drives a real browser through all slides — including vertical sub-slides —
    with every fragment revealed, and reports:

      * slides whose content is taller than the configured slide height
      * any JavaScript error raised while walking the deck

    Overflow is the failure this exists for: nothing errors, the content just
    runs off the bottom of the projector, and you find out on stage. Widget
    slides are the usual offenders because a panel grows as you add to it.

    Serves the deck itself unless -Url is given, and stops the server after.

    Requires agent-browser:  npm i -g agent-browser && agent-browser install

.EXAMPLE
    Test-DeckLayout.ps1 -Path D:\talks\my-talk\deck

.EXAMPLE
    Test-DeckLayout.ps1 -Url http://localhost:8081/index.html
#>
[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
    # Deck folder. The script serves it on a free port and stops the server after.
    [Parameter(Mandatory, ParameterSetName = 'Path')]
    [string]$Path,

    # Test an already-running deck instead of serving one.
    [Parameter(Mandatory, ParameterSetName = 'Url')]
    [string]$Url,

    [Parameter(ParameterSetName = 'Path')]
    [int]$Port = 8099,

    # Leave the browser open at the last slide (for poking at a failure).
    [switch]$KeepBrowser
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command agent-browser -ErrorAction SilentlyContinue)) {
    Write-Error 'agent-browser is not on PATH. Install it with:  npm i -g agent-browser && agent-browser install'
    exit 2
}

$server = $null
try {
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path (Join-Path $Path 'index.html'))) {
            Write-Error "No index.html in $Path"
            exit 2
        }
        $Path = (Resolve-Path $Path).Path
        if (-not (Test-Path (Join-Path $Path 'node_modules/reveal.js'))) {
            Write-Error "reveal.js is not installed in $Path. Run npm install there first."
            exit 2
        }

        $Url = "http://127.0.0.1:$Port/index.html"
        Write-Host "Serving $Path on port $Port..." -ForegroundColor DarkGray

        # Run the locally installed http-server through node directly.
        # Start-Process -FilePath 'npx' fails on Windows: the launcher is
        # npx.cmd, and Start-Process will not resolve a PATHEXT extension.
        $serverBin = Join-Path $Path 'node_modules\http-server\bin\http-server'
        if (Test-Path $serverBin) {
            $exe = (Get-Command node).Source
            $serverArgs = @($serverBin, '.', '-p', "$Port", '-c-1', '--silent')
        } else {
            $npx = Get-Command npx -ErrorAction SilentlyContinue
            if (-not $npx) {
                Write-Error "http-server is not installed in $Path and npx is not on PATH. Run npm install in the deck folder."
                exit 2
            }
            $exe = $npx.Source
            $serverArgs = @('http-server', '.', '-p', "$Port", '-c-1', '--silent')
        }

        $server = Start-Process -FilePath $exe -ArgumentList $serverArgs `
            -WorkingDirectory $Path -PassThru -WindowStyle Hidden

        $up = $false
        foreach ($i in 1..25) {
            Start-Sleep -Milliseconds 400
            try {
                if ((Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) {
                    $up = $true; break
                }
            } catch { }
        }
        if (-not $up) {
            Write-Error "Server did not come up on $Url"
            exit 2
        }
    }

    Write-Host "Walking every slide at $Url" -ForegroundColor Cyan

    # `agent-browser open` can hang indefinitely on a cold Chrome start, long
    # after the page is loaded and answering evals. So fire it off detached and
    # confirm readiness by polling the page itself rather than waiting on it.
    #
    # Start-Process, not Start-Job: a job that owns a hung child cannot be
    # stopped either -- Stop-Job blocks on it and takes the whole script with
    # it. Start-Process hands back a pid we can kill outright.
    # -FilePath needs a real executable. npm global installs put THREE shims on
    # PATH -- .ps1, .cmd and a shell script -- and in pwsh a bare Get-Command
    # returns the .ps1, which Start-Process cannot launch ("the system cannot
    # find all the information required"). Ask for the Application entry.
    $abApp = Get-Command agent-browser -All -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -eq 'Application' } | Select-Object -First 1
    if ($abApp) {
        $opener = Start-Process -FilePath $abApp.Source -ArgumentList 'open', $Url `
            -PassThru -WindowStyle Hidden
    } else {
        # only the PowerShell shim is on PATH -- run it through this host
        $opener = Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList '-NoProfile', '-File', (Get-Command agent-browser).Source, 'open', $Url `
            -PassThru -WindowStyle Hidden
    }

    # A cold Chrome start can eat the whole budget before the navigation lands,
    # leaving a live browser sitting on about:blank. So poll for the DECK, and
    # if the browser is answering but is on the wrong page, ask again -- a
    # second `open` against a warm browser returns immediately.
    $probe = "typeof Reveal !== 'undefined' && Reveal.isReady() && !!document.querySelector('#rail .chap')"
    $budget = 120                                # x 750ms = 90s
    $ready = $false
    for ($i = 1; $i -le $budget; $i++) {
        Start-Sleep -Milliseconds 750
        $answer = (& agent-browser eval $probe 2>$null | Select-Object -Last 1)
        if ($answer -and $answer -match 'true') { $ready = $true; break }

        if ($abApp -and $i % 12 -eq 0) {
            $here = (& agent-browser get url 2>$null | Select-Object -Last 1)
            if ($here -and $here -notmatch [regex]::Escape($Url)) {
                Write-Host "  browser is up but on $here - re-issuing the open" -ForegroundColor DarkGray
                if ($opener -and -not $opener.HasExited) {
                    Stop-Process -Id $opener.Id -Force -ErrorAction SilentlyContinue
                }
                $opener = Start-Process -FilePath $abApp.Source -ArgumentList 'open', $Url `
                    -PassThru -WindowStyle Hidden
            }
        }
    }
    if ($opener -and -not $opener.HasExited) {
        Stop-Process -Id $opener.Id -Force -ErrorAction SilentlyContinue
    }

    if (-not $ready) {
        Write-Error "The deck did not become ready at $Url within 90s. Open it in a browser and check the console."
        exit 2
    }

    # Walks the deck, revealing all fragments, and measures the innermost
    # .present section — for a vertical stack the wrapper is .present too, and
    # its scrollHeight is the sum of its children, which reads as a false
    # positive if you take the first match.
    $js = @'
(async () => {
  const errors = [];
  window.addEventListener('error', e => errors.push(String(e.message)));
  const H = Reveal.getConfig().height;
  const index = [], overflow = [];
  document.querySelectorAll('.reveal .slides > section').forEach((sec, h) => {
    const kids = sec.querySelectorAll(':scope > section');
    if (kids.length) kids.forEach((k, v) => index.push([h, v]));
    else index.push([h, 0]);
  });
  for (const [h, v] of index) {
    Reveal.slide(h, v);
    await new Promise(r => setTimeout(r, 110));
    while (Reveal.availableFragments().next) Reveal.nextFragment();
    await new Promise(r => setTimeout(r, 60));
    const all = document.querySelectorAll('section.present');
    const s = all[all.length - 1];
    if (s.scrollHeight > H + 4) {
      overflow.push({
        slide: (h + 1) + (v ? '.' + (v + 1) : ''),
        title: s.dataset.title || ('slide ' + (h + 1)),
        height: s.scrollHeight,
        frame: H
      });
    }
  }
  return JSON.stringify({ total: index.length, frame: H, overflow, errors });
})()
'@

    $raw = agent-browser eval $js
    if (-not $KeepBrowser) { agent-browser close | Out-Null }

    # eval returns the JSON string, itself JSON-quoted
    $json = $raw | Select-Object -Last 1
    $result = ($json | ConvertFrom-Json) | ConvertFrom-Json

    Write-Host ''
    Write-Host "Slides walked: $($result.total)   frame height: $($result.frame)px" -ForegroundColor DarkGray

    $failed = $false

    if ($result.errors.Count -gt 0) {
        $failed = $true
        Write-Host ''
        Write-Host "JavaScript errors ($($result.errors.Count)):" -ForegroundColor Red
        $result.errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }

    if ($result.overflow.Count -gt 0) {
        $failed = $true
        Write-Host ''
        Write-Host "Slides taller than the frame ($($result.overflow.Count)):" -ForegroundColor Yellow
        $result.overflow | ForEach-Object {
            $over = $_.height - $_.frame
            Write-Host ("  {0,-6} {1,-44} {2}px  (+{3}px)" -f $_.slide, $_.title, $_.height, $over) -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host 'Fix by trimming content, not by shrinking the frame: cut lines from the' -ForegroundColor DarkGray
        Write-Host 'snippet, shorten the pull quote, or move detail to a vertical sub-slide.' -ForegroundColor DarkGray
    }

    if (-not $failed) {
        Write-Host ''
        Write-Host 'All slides fit the frame, no JavaScript errors.' -ForegroundColor Green
    }

    if ($failed) { exit 1 }
    exit 0
}
finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
}
