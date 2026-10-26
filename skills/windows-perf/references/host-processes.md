# When the top row is a host: browsers, Node, test runners

Part of the [windows-perf](../SKILL.md) skill.

`msedge`, `chrome`, `node` and `dotnet` name a runtime, not the work inside it. Name the
page or the command before acting on one of them, otherwise the "fix" is closing a whole
browser or killing another session's job.

## Group by name before ranking

A browser spreads its load over dozens of processes, so no single row looks guilty while
the group holds a core. Sum per name first:

```powershell
$cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
  Where-Object { $_.Name -notin '_Total','Idle' } |
  Group-Object { $_.Name -replace '#\d+$','' } |
  ForEach-Object { [pscustomobject]@{
      Name  = $_.Name
      Count = $_.Count
      CPU   = [math]::Round(($_.Group | Measure-Object PercentProcessorTime -Sum).Sum / $cores, 1)
      WS_GB = [math]::Round(($_.Group | Measure-Object WorkingSetPrivate -Sum).Sum / 1GB, 2) } } |
  Sort-Object CPU -Descending | Select-Object -First 12 | Format-Table -AutoSize
```

## Browser: which process type, then which tab

Chromium browsers put the process role on the command line (`--type=gpu-process`,
`--type=renderer`, `--extension-process`, `--utility-sub-type=...`; no `--type` is the main
browser process). Join on `IDProcess`, not on the counter instance name (`msedge#13` is an
arbitrary index):

```powershell
$cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$cmd = @{}; Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | ForEach-Object { $cmd[[int]$_.ProcessId] = "$($_.CommandLine)" }
Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter "Name like 'msedge%'" |
  Sort-Object PercentProcessorTime -Descending | Select-Object -First 6 | ForEach-Object {
    $c = $cmd[[int]$_.IDProcess]
    $type = if ($c -match '--type=(\S+)') { $matches[1] } else { 'browser' }
    if ($c -match '--extension-process') { $type += ' (extension)' }
    '{0,6} {1,5:N1}%  {2}' -f $_.IDProcess, ($_.PercentProcessorTime / $cores), $type }
```

**A busy `gpu-process` plus one busy renderer means a page that never stops drawing:** a
canvas, WebGL or CSS animation redrawn at display refresh rate. To name it, open the
browser's own task manager (**Shift+Esc** in Edge and Chrome) and sort by CPU. Its
*Process ID* column matches the renderer PID above.

Measured on a 16-thread desktop: one visible tab running an always-on animated dashboard
held its renderer at ~29% of one core, with the GPU process at ~8% of the box, about 10% of
the machine for a page nobody was looking at closely.

Things that make it confusing:

- **Visibility decides the cost.** Browsers throttle `requestAnimationFrame` for minimized
  or fully covered windows and hidden tabs. The same page as an installed app (PWA) sat at
  0.7% while minimized, and climbed to the tab's cost once its window was visible. Closing
  the tab moves the cost; it does not remove it.
- **Two `gpu-process` rows means two browser instances** (a second profile or an app
  window with its own process tree), each compositing its own visible content.

Stopgap: close or minimize the page. Real fix, in the page itself: cap the frame rate for
ambient motion, skip frames when nothing changed, stop on `document.hidden`, and honour
`prefers-reduced-motion`.

## Node / dotnet bursts: read the command line

When the load comes in bursts that are gone by the next look, list the runtime processes
with start time, parent and command line:

```powershell
Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Sort-Object CreationDate | ForEach-Object {
  $c = "$($_.CommandLine)" -replace '\s+', ' '
  '{0,6} {1:HH:mm:ss} parent {2,6}  {3}' -f $_.ProcessId, $_.CreationDate, $_.ParentProcessId, $c.Substring(0, [math]::Min(140, $c.Length)) }
```

A group of workers sharing one start second, all under the same `node_modules` path, is a
test runner's worker pool (vitest, jest). The path names the checkout; the parent chain
leads back to the shell that started it.

**With AI coding agents running in parallel worktrees, this is the usual cause of "the PC
is slow".** Each agent runs the full suite to check its own change. One run measured on a
16-thread box used 7 workers, took ~63% of the machine on its own and the total to 95%;
the same session repeated it every few minutes. Real-time antivirus adds a few percent
scanning the files each run touches.

Don't kill it — it is another session's work. Ask that session to run only the tests its
change affects, cap the pool (`--maxWorkers=4` for vitest and jest), and do one full run at
the end. Defender's share during the runs is expected on a trusted Dev Drive (performance
mode, asynchronous scan) and is not a reason to add exclusions — see the
`windows-defender-dev` skill.

The same reading applies to `dotnet` (`dotnet test`, `testhost.exe`, `VBCSCompiler.exe`)
and to `java`/`gradle` daemons.
