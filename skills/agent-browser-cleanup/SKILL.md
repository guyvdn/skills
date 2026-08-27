---
name: agent-browser-cleanup
description: 'Use this skill only when the user explicitly asks about leaked, orphaned or runaway browser processes left behind by agent-browser (or a similar CDP automation CLI) — hundreds of chrome.exe entries, gigabytes of RAM held by an idle machine, or `agent-browser close --all` reporting success while browsers keep running.'
version: 1.0.0
---

# agent-browser orphan cleanup

Find and remove Chrome trees that `agent-browser` launched and then lost track of,
and stop them accumulating again.

## Symptom

- Hundreds of `chrome.exe` processes, gigabytes of working set, on an otherwise idle
  machine.
- `agent-browser close --all` says `✓ Closed session: default` and the processes keep
  running.
- `%TEMP%` filling with `agent-browser-chrome-<guid>` profile directories.

## Why it happens

`agent-browser` launches Chrome and waits for it to write `DevToolsActivePort` into
the profile directory. If that wait times out it reports:

```
Auto-launch failed: Chrome exited early (exit code: 0) without writing DevToolsActivePort
```

and retries. **The browser from the "failed" attempt is alive** — it just answered too
slowly — and nothing tracks it any more. Chrome's launcher process detaches the real
browser and exits 0, which is what the timeout misreads as a crash.

Two things make it compound:

- The wait is on the order of a second, and Chrome cold start on a loaded machine sits
  right at that boundary. Measure it before blaming anything else (see below).
- Every leaked browser makes the next launch slower, which causes more retries. One
  `open` can leave several live trees; a busy session can leave dozens.

`close --all` cannot help, because session tracking files are keyed on the session
name (`<session>.pid`, `<session>.port`). Each launch that reuses a session name
overwrites the previous launch's files, so only the most recent browser is still
reachable. Everything before it is invisible to the CLI.

## Detecting an orphan — do not use "the parent is dead"

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

## Cleaning up

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

## Preventing it

**1. Cut Chrome's cold start.** The leak is a race against a hardcoded timeout, so the
fix is to win the race. On Windows, exclude the browser cache and the profile
directories from Defender real-time scanning:

```powershell
Add-MpPreference -ExclusionPath "$env:USERPROFILE\.agent-browser\browsers",
                                "$env:TEMP\agent-browser-chrome-*"
```

Then measure, rather than assuming it worked:

```powershell
$exe = (Get-ChildItem "$env:USERPROFILE\.agent-browser\browsers\*\chrome.exe" | Select-Object -First 1).FullName
$udd = Join-Path $env:TEMP "ab-timing-$(Get-Random)"
$sw  = [Diagnostics.Stopwatch]::StartNew()
Start-Process $exe -ArgumentList "--headless","--remote-debugging-port=0","--user-data-dir=`"$udd`"","--no-first-run","about:blank" -WindowStyle Hidden | Out-Null
while ($sw.Elapsed.TotalSeconds -lt 30 -and -not (Test-Path (Join-Path $udd 'DevToolsActivePort'))) { Start-Sleep -Milliseconds 20 }
"$([math]::Round($sw.Elapsed.TotalSeconds,2))s to DevToolsActivePort"
```

Expect a few hundred milliseconds. If the worst case is close to a second, expect
leaks under load — exclusions help but may not fully close the gap.

**2. Reap on a schedule.** Because the leak compounds *within* a session, cleaning up
only at session start lets it grow all day. Run the cleanup script periodically —
e.g. from an agent lifecycle hook that fires when a turn ends.

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

**3. Consider reusing one browser.** `--auto-connect` attaches to an already-running
Chrome instead of launching a fresh one, which sidesteps the launch race entirely for
workflows that can tolerate a shared browser.

## Gotchas

- **Never match on process name alone.** Filter on `ExecutablePath` under
  `~/.agent-browser`; otherwise you will kill the user's real Chrome.
- **`agent-browser doctor` can pass while the leak is active.** Its built-in launch
  test uses a longer timeout than the `open` path, so it reports a healthy launch on a
  machine that leaks a browser on every command. `doctor --fix` does clear stale
  daemon files, which is still worth running.
- **The handshake timeout is not configurable.** No `AGENT_BROWSER_*` variable exposes
  it — `AGENT_BROWSER_DEFAULT_TIMEOUT` is for actions and `AGENT_BROWSER_IDLE_TIMEOUT_MS`
  is daemon idle. Do not go looking for a knob; reduce launch latency instead.
- **Verify a reap with a negative test too.** Start a session, confirm the script
  leaves it alone, *then* kill the daemon and confirm it reaps. A cleanup that passes
  only the positive test may be killing live sessions.
