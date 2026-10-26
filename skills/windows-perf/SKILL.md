---
name: windows-perf
description: 'Use this skill only when the user explicitly asks why a Windows PC is slow, to diagnose CPU spikes, fix Windows performance issues, disable telemetry services, clean up startup items, or work out why a laptop fan never stops on Windows.'
version: 1.4.0
---

# Windows Performance Tuning

Diagnose CPU load and disable unnecessary services and startup items on a Windows
developer machine. Steps 1–4 below find the load; the reference files listed under
[Where to look next](#where-to-look-next) cover what to do about it.

> **Admin steps** (service changes, Defender settings, `fsutil`, power settings): on
> Windows 11 24H2+ with **sudo** enabled (Settings ▸ System ▸ Advanced, mode *Input
> closed*), run them per command from an unelevated shell —
> `sudo pwsh -NoProfile -Command "..."`, each call raising one UAC prompt. Don't elevate
> the whole agent session: Chromium refuses to run elevated (breaking browser automation),
> and `subst` drives created unelevated are invisible to an elevated token.

## Step 1 — Get an honest total first

Before hunting a culprit, establish how much CPU is actually in use. Task Manager
routinely shows a total that its own process rows do not add up to — its header and
its rows are sampled at **different instants**, so a momentary spike lands in the
header while the rows show the next tick.

Sample the total and the per-process figures in **one** `Get-Counter` call so they
share a timestamp:

```powershell
$s = Get-Counter -Counter '\Processor Information(_Total)\% Processor Time',
                          '\Process(*)\% Processor Time' -SampleInterval 3 -MaxSamples 3
$cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
foreach ($set in $s) {
  $tot   = ($set.CounterSamples | Where-Object Path -like '*processor information*').CookedValue
  $procs = $set.CounterSamples | Where-Object { $_.Path -like '*\process(*' -and $_.InstanceName -notin '_total','idle' }
  $sum   = (($procs | Measure-Object CookedValue -Sum).Sum) / $cores
  '{0,5:N1}% total   {1,5:N1}% summed   gap {2,4:N1}%' -f $tot, $sum, ($tot - $sum)
}
```

The gap should land within a few percent — that residue is interrupt and DPC time,
which belongs to no process. **A large gap means your two numbers came from
different moments, not that CPU is hiding somewhere.** Do not go hunting for a
phantom process until you have reproduced the gap in a simultaneous sample.

`\Process(*)` counters are summed across all cores, so divide by the logical
processor count to express them as a share of the whole machine.

## Step 2 — Split kernel from user, and rule out drivers

```powershell
Get-Counter -Counter '\Processor Information(_Total)\% Processor Time',
                     '\Processor Information(_Total)\% User Time',
                     '\Processor Information(_Total)\% Privileged Time',
                     '\Processor Information(_Total)\% Interrupt Time',
                     '\Processor Information(_Total)\% DPC Time',
                     '\System\Context Switches/sec',
                     '\System\System Calls/sec' -SampleInterval 2 -MaxSamples 2
```

Read it like this:

| Shape | Means |
|---|---|
| High **% Interrupt** + **% DPC** (>5–10%) | A driver is misbehaving. Chase the driver, not a process. |
| High **% Privileged** vs **% User**, huge **System Calls/sec** | Kernel-side work — usually a filter driver: AV real-time scanning, backup/sync agents, virtual disk or display drivers. |
| High **% User** | Ordinary userland work. Step 3 will name it. |

## Step 3 — Find the process

```powershell
Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
  Where-Object { $_.PercentProcessorTime -gt 1 -and $_.Name -notin '_Total','Idle' } |
  Sort-Object PercentProcessorTime -Descending |
  Select-Object -First 15 Name, PercentProcessorTime, IDProcess |
  Format-Table -AutoSize
```

> `Get-Process | Sort-Object CPU` shows cumulative seconds since start — not current
> load. Always confirm with perf counters.

These values are also per-core sums: on a 16-core machine `100` means one core fully
busy, roughly 6% of the box. Divide by the core count before reporting a percentage.

Then get details:

```powershell
Get-Process -Id <pid> | Select-Object Name, Id, Path, StartTime, CPU | Format-List
```

If the top rows are a browser (`msedge`, `chrome`) or a runtime (`node`, `dotnet`), the row
names the host, not the work. Read [references/host-processes.md](references/host-processes.md)
before acting: group by name, find the tab or command line, and check whether the burst is
a parallel agent session's test run.

## Step 4 — If no process accounts for it, check process churn

A storm of short-lived processes burns real CPU while being almost invisible to
sampling, because each one is gone before the next sample:

```powershell
$a = @{}; Get-CimInstance Win32_Process | ForEach-Object { $a["$($_.ProcessId)|$($_.CreationDate)"] = $_.Name }
Start-Sleep -Seconds 10
$b = @{}; Get-CimInstance Win32_Process | ForEach-Object { $b["$($_.ProcessId)|$($_.CreationDate)"] = $_.Name }
$new = $b.Keys | Where-Object { -not $a.ContainsKey($_) }
"started in 10s: $($new.Count)"
$new | ForEach-Object { $b[$_] } | Group-Object | Sort-Object Count -Descending | Select-Object -First 10 Count, Name
```

A handful per 10s is normal. Dozens per second is the finding.

## Where to look next

| About to… | Read |
|---|---|
| Name the tab or command behind a busy browser, `node` or `dotnet` | [references/host-processes.md](references/host-processes.md) |
| Disable a service, or run the cleanup script (services and startup items it touches) | [references/cleanup.md](references/cleanup.md) |
| Work out why the fan never stops — background load vs turbo, idle WSL/Kubernetes VM, disabling turbo | [references/fan-and-thermals.md](references/fan-and-thermals.md) |
| Trust a counter, a thermal zone or a frequency reading | [references/gotchas.md](references/gotchas.md) |

