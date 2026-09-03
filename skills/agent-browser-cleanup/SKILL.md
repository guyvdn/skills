---
name: agent-browser-cleanup
description: 'Use this skill when agent-browser (or a similar CDP automation CLI) fails to launch a browser — "Auto-launch failed: Chrome exited early (exit code: 0) without writing DevToolsActivePort" — or when it leaves leaked, orphaned or runaway Chrome processes behind: hundreds of chrome.exe entries, gigabytes of RAM held by an idle machine, `agent-browser close --all` reporting success while browsers keep running, or a command that hangs forever with no output.'
version: 1.1.0
---

# agent-browser launch failures and orphan cleanup

Get `agent-browser` launching again, find and remove Chrome trees it launched and then
lost track of, and stop them accumulating.

## Symptoms

Two shapes, with the same error text and the same leak:

**A. Every command fails, on an idle machine.** `open`, `get`, even `doctor`'s launch
test report:

```
Auto-launch failed: Chrome exited early (exit code: 0) without writing DevToolsActivePort
(also tried parsing stderr) Chrome exited before providing DevTools URL (no stderr output from Chrome)
Hint: try passing --args "--no-sandbox" if Chrome crashes silently in your environment
```

Reinstalling and adding Defender exclusions change nothing. This is almost always
**cause 1 below (an elevated shell)** — go there first.

**B. It works, but leaks.** Hundreds of `chrome.exe` processes, gigabytes of working
set, `%TEMP%` filling with `agent-browser-chrome-<guid>` profile directories, and
`agent-browser close --all` saying `✓ Closed session: default` while the processes keep
running. That is **cause 2**, a race under load.

A third symptom has nothing to do with launching — see *Piping stdout hangs forever* in
Gotchas. Rule it out first, because it looks exactly like a hung browser.

## Why it happens

Both causes share one mechanism. `agent-browser` launches `chrome.exe` and waits for
the browser to write `DevToolsActivePort` into the profile directory. On Windows the
process it launched is only a **launcher**: it detaches the real browser and exits 0.
If the port file is not there yet at that moment, `agent-browser` reads "exited 0, no
port" as a crash, reports failure and retries — while the browser from the "failed"
attempt is alive and no longer tracked by anything.

### Cause 1 — the shell is elevated (Chrome de-elevates itself)

Chrome refuses to run elevated on Windows. Launched from a High Mandatory Level
process, it **relaunches itself de-elevated** and the original exits 0 immediately.
The relaunched browser does come up and does write `DevToolsActivePort` — but it is a
different process that `agent-browser` never had a handle on, so auto-launch fails
*every single time*, not just under load, and leaks a full tree on every attempt.

Claude Code's shell runs elevated on some Windows setups, which is exactly this case.
Check before anything else:

```powershell
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
"elevated: " + (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
whoami /groups | Select-String 'Mandatory Level'
```

`High Mandatory Level` plus a fast port write (see the measurement below) confirms it.
A second confirmation is in the process table: the tree root's parent pid is already
gone.

Do not reach for `--args "--no-sandbox"` here. The printed hint is about sandbox
crashes; de-elevation happens regardless of the sandbox flag.

### Cause 2 — cold start loses the race

Without elevation in play, the same failure appears when Chrome's cold start drifts
past the handshake wait, which is on the order of a second. This one compounds: every
leaked browser makes the next launch slower, so one `open` can leave several live
trees and a busy session dozens.

**Measure before blaming latency** — this is what separates the two causes:

```powershell
$exe = (Get-ChildItem "$env:USERPROFILE\.agent-browser\browsers\*\chrome.exe" | Select-Object -First 1).FullName
$udd = Join-Path $env:TEMP "ab-timing-$(Get-Random)"
$sw  = [Diagnostics.Stopwatch]::StartNew()
Start-Process $exe -ArgumentList "--headless","--remote-debugging-port=0","--user-data-dir=`"$udd`"","--no-first-run","about:blank" -WindowStyle Hidden | Out-Null
while ($sw.Elapsed.TotalSeconds -lt 30 -and -not (Test-Path (Join-Path $udd 'DevToolsActivePort'))) { Start-Sleep -Milliseconds 20 }
"$([math]::Round($sw.Elapsed.TotalSeconds,2))s to DevToolsActivePort"
```

- A few hundred milliseconds **and** `agent-browser` still fails → cause 1. Latency is
  not the problem; stop tuning it.
- Close to or past a second → cause 2. Cut the cold start (below).

## Fixing cause 1 — pre-launch Chrome, connect over CDP

An elevated shell cannot hand `agent-browser` a browser it can track, so do not let it
launch one. Start Chrome yourself and attach:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Start-AgentBrowserCdp.ps1
# -Headed to watch it, -Port to move off 9222, -Force if the profile is locked,
# -Stop to shut it down
```

Idempotent: if the port already answers it reuses that browser and launches nothing.
It picks the newest Chrome under `~/.agent-browser/browsers` (then puppeteer's cache,
then a system install) and puts the profile in `%LOCALAPPDATA%`, deliberately outside
`%TEMP%` so the cleanup script's stale-profile sweep cannot delete it.

It also **polls the DevTools endpoint rather than watching the process it started** —
under de-elevation that process is gone within milliseconds while the real browser is
still coming up, so the process handle is worthless as a readiness signal. This is the
same trap `agent-browser` itself falls into.

Then every call gets `--cdp`, and no pipes:

```bash
agent-browser --cdp 9222 open <url>          >out.log 2>&1 </dev/null
agent-browser --cdp 9222 screenshot shot.png >>out.log 2>&1 </dev/null
```

The de-elevation relaunch still happens, but it is Chrome's own business now: the
DevTools endpoint binds on localhost and is reachable whatever integrity level the
browser ended up at. Measured cost: endpoint up in ~0.4s, and one browser is reused by
every subsequent command.

`--auto-connect` (or `AGENT_BROWSER_AUTO_CONNECT`) does the same thing by discovering a
running Chrome, which is nicer when you can tolerate the user's own browser and its
auth state. `--cdp` on a dedicated profile is the predictable choice for automation.

A pre-launched browser does not die with the session — close it when done
(`-Stop`), or leave it as the working setup and say so.

## Cleaning up leaked trees

```powershell
# see what would go
powershell -ExecutionPolicy Bypass -File scripts/Remove-OrphanedAgentBrowsers.ps1 -DryRun

# remove them
powershell -ExecutionPolicy Bypass -File scripts/Remove-OrphanedAgentBrowsers.ps1
```

No admin needed — these are user-owned processes. The script kills orphaned trees,
drops a daemon left holding stale `.pid`/`.port` files, and removes stale
`%TEMP%\agent-browser-chrome-*` profile directories that no running browser is using.

`-MinAgeMinutes` (default 5) ignores browsers younger than that, so a launch still in
progress is never reaped. `-KeepTempProfiles` leaves the profile directories alone.

Killing a tree's root takes its children with it, so `Stop-Process` on the
already-dead children reports "Cannot find a process with the process identifier N".
That is expected, not a failure.

### Detecting an orphan — do not use "the parent is dead"

`agent-browser` **detaches every browser it launches**, so a perfectly healthy tree
also has a dead parent. Using dead-parent as the signal flags live sessions and will
kill browsers out from under a running agent.

The reliable signal is the daemon: a browser can only belong to a daemon that already
existed when the browser started. So a tree is an orphan when:

- there is **no live daemon at all**, or
- it **started before the earliest live daemon**.

Trees started after a live daemon are left alone — from outside the process table
there is no way to tell which one that daemon actually holds.

Match browsers by **executable path** under `~/.agent-browser`, never by process name.
A bare `chrome` name match also hits the user's real browser.

One more exclusion is needed once you pre-launch for `--cdp`. That browser is started
by hand *before* any daemon exists, so the rule above flags it every single time — and
reaping it kills the browser the session is working in. It also uses the same
`~/.agent-browser` Chrome, so the executable-path filter does not separate it either.
What does separate it is the profile: only `agent-browser`'s own launches land in
`%TEMP%\agent-browser-chrome-*`, so the script treats that profile shape as the only
fair game and spares everything else, reporting `spared : N pre-launched`.
`-IncludeExternalProfiles` opts out when you know no pre-launched browser is in play.

### The script will not reap a cause-1 leak

Under cause 1 the daemon starts fine and stays alive; only the browsers fail. Every
leaked tree is therefore *newer* than the live daemon, so the orphan rule above spares
all of them — a dry run reports something like `6 browser trees (0 orphaned)` while a
hundred processes sit there. That is the rule working as designed, not a bug: from
outside, any one of those trees could be the daemon's.

Clear them by hand once the daemon is stopped, filtering on executable path so the
user's own Chrome is untouched:

```powershell
agent-browser close --all
agent-browser doctor --fix
Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
    Where-Object { $_.ExecutablePath -like "*\.agent-browser\*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
```

Then fix the launch path, or the next command starts the pile again.

## Preventing a cause-2 leak

**1. Cut Chrome's cold start.** The race is against a hardcoded timeout, so the fix is
to win it. Exclude the browser cache and the profile directories from Defender
real-time scanning:

```powershell
Add-MpPreference -ExclusionPath "$env:USERPROFILE\.agent-browser\browsers",
                                "$env:TEMP\agent-browser-chrome-*"
```

Then re-run the measurement above rather than assuming it worked. Exclusions help but
may not fully close the gap, and they do **nothing** for cause 1 — if the port write is
already fast, adding them is treating the wrong problem.

**2. Reap on a schedule.** Because the leak compounds *within* a session, cleaning up
only at session start lets it grow all day. Run the cleanup script periodically — e.g.
from an agent lifecycle hook that fires when a turn ends.

Gate it, though: spawning a PowerShell host costs roughly half a second before the
script does anything, which is too much to pay every turn. A stamp-file check in a
cheaper runtime keeps the common path near-free:

```javascript
const fs = require('fs'), path = require('path');
const { spawnSync } = require('child_process');
const INTERVAL_MS = 5 * 60 * 1000;
const stamp = path.join(process.env.TEMP || '.', '.agent-browser-reap-stamp');
try { if (Date.now() - fs.statSync(stamp).mtimeMs < INTERVAL_MS) process.exit(0); } catch {}
try { fs.writeFileSync(stamp, ''); } catch {}   // touch first, so a slow run still backs off
const r = spawnSync('pwsh', ['-NoProfile', '-File', '<path>/Remove-OrphanedAgentBrowsers.ps1'],
                    { encoding: 'utf8', windowsHide: true });
if (r.stdout?.trim()) process.stdout.write(r.stdout);
```

A 5-minute interval costs nothing in coverage: the script's own `-MinAgeMinutes`
default is 5, so running more often cannot surface anything new.

**3. Reuse one browser.** The `--cdp` / `--auto-connect` setup above sidesteps the
launch race entirely, so it is worth having even when elevation is not the problem.

## Gotchas

- **Piping stdout hangs forever.** `agent-browser` spawns a daemon that inherits
  stdout, so `agent-browser open <url> | tail -5` never sees EOF and blocks until the
  harness timeout — even though the command itself finished in about a second. It looks
  identical to a browser that never came up, and it will send you diagnosing the wrong
  thing. Redirect instead: `agent-browser open <url> >out.log 2>&1 </dev/null`, then
  read the file. Wrapping in `timeout` does not save you; the daemon holds the pipe
  after the CLI is killed.
- **Never match on process name alone.** Filter on `ExecutablePath` under
  `~/.agent-browser`; otherwise you will kill the user's real Chrome.
- **`agent-browser doctor` is inconsistent about the launch test.** Under cause 1 it
  fails it (`Browser launch failed: Chrome exited early`), which is a useful
  confirmation. Under cause 2 it can *pass* while the leak is active, because its
  launch test uses a longer timeout than the `open` path — so a pass is not evidence of
  a healthy launch. `doctor --fix` does clear stale daemon files, which is worth
  running either way.
- **A missing browser is not the problem.** `doctor` lists the Chrome it found under
  `~/.agent-browser/browsers`; if that line passes, `agent-browser install` will not
  help however many times it is run.
- **The handshake timeout is not configurable.** No `AGENT_BROWSER_*` variable exposes
  it — `AGENT_BROWSER_DEFAULT_TIMEOUT` is for actions and `AGENT_BROWSER_IDLE_TIMEOUT_MS`
  is daemon idle. Do not go looking for a knob; remove the launch instead (`--cdp`) or
  reduce its latency.
- **Verify a reap with a negative test too.** Start a session, confirm the script
  leaves it alone, *then* kill the daemon and confirm it reaps. A cleanup that passes
  only the positive test may be killing live sessions. This is not hypothetical: it is
  how the pre-launched-browser exclusion above was found, on a reaper that had passed
  its positive test for months. With a pre-launched browser up, the pair to run is
  `-DryRun -MinAgeMinutes 0` (must report it spared) and the same with
  `-IncludeExternalProfiles` (must report it orphaned).
