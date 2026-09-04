---
name: windows-perf
description: 'Use this skill only when the user explicitly asks to diagnose CPU spikes, fix Windows performance issues, disable telemetry services, clean up startup items, or work out why a laptop fan never stops on Windows.'
version: 1.2.0
---

# Windows Performance Tuning

Diagnose CPU load and disable unnecessary services and startup items on a Windows
developer machine.

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

## Step 5 — Disable the offending service

```powershell
Stop-Service <ServiceName> -Force
Set-Service <ServiceName> -StartupType Disabled
```

If the process lingers after stopping the service:

```powershell
taskkill /PID <pid> /F
```

## Step 6 — Run the cleanup script

Disables known CPU-hungry and telemetry services and removes unnecessary startup
items. Requires admin PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Disable-UnnecessaryServices.ps1

# also disable IIS (opt-in; see the note below)
powershell -ExecutionPolicy Bypass -File scripts/Disable-UnnecessaryServices.ps1 -IncludeIIS
```

### Services the script disables

| Service | Description |
|---|---|
| `SNAPOService` | Sonitude audio APO — known CPU spinner, not needed with Bluetooth headphones |
| `CxUtilSvc` / `CxMonSvc` | Conexant audio utilities |
| `DiagTrack` | Windows Connected User Experiences & Telemetry |
| `HPAudioAnalytics` | HP audio analytics |
| `HpTouchpointAnalyticsService` | HP Touchpoint analytics |
| `hpLHAgent` / `hpLHWatchdog` | HP Insights telemetry agent |
| `Intel Analytics Service` | Intel telemetry |
| `dptftcs` | Intel Dynamic Tuning Technology **Telemetry** service |

### Services the script deliberately leaves alone

| Service | Why |
|---|---|
| `ipfsvc` | **Intel Innovation Platform Framework — not telemetry.** On modern Intel mobile parts this is the dynamic power and thermal manager; it trims sustained power limits so the chassis does not sit hot. Measured over 3 minutes on a 13th-gen P-series laptop, `ipf_helper.exe` and `ipf_uf.exe` both held 0% CPU. Disabling it saves nothing and removes thermal management. |
| `W3SVC` (IIS) | Opt-in via `-IncludeIIS`. Many developer machines host sites on local IIS, and an idle W3SVC costs almost nothing. Do not disable it on a .NET box without asking. |

Judge a service by its **display name and actual role**, not by the vendor prefix.
Run `Get-Service <name> | Select-Object Name, DisplayName` before assuming "Intel" or
"HP" means telemetry.

### Startup items the script removes

| Entry | Description |
|---|---|
| `MicrosoftEdgeAutoLaunch_*` | Edge silent background launch |
| `GoogleChromeAutoLaunch_*` | Chrome silent background launch |
| `Adobe Acrobat Synchronizer` | Acrobat collaboration sync |
| `StartLoad` | Yealink Wireless Presentation Pod |
| `ClickShare` | Barco ClickShare presentation tool |

## The fan never stops but no process looks guilty

There are **two different causes** here, and they need different fixes. Establish
which one you have before changing anything.

| Symptom | Cause | Fix |
|---|---|---|
| Modest utilization, frequency at or below base | **Sustained background load** — a dozen idle-but-not-quiet services totalling 10–15% keeps a 28W mobile part warm, and no single row in Task Manager looks worth killing. | Reduce background load (Steps 3–6). |
| Modest utilization, frequency **above** base | **Sustained turbo on light load** — light, scattered work across many cores holds the package at high clocks. Power scales with V²·f, so heat comes from frequency, not from utilization. | Disable turbo (below). |

The second case is easy to misdiagnose as the first, because both show a low
percentage in Task Manager. Task Manager's frequency readout is not reliable enough
to tell them apart — use the counter.

Check, in order:

```powershell
# 1. Is the fan forced on by firmware rather than by heat? (HP example)
Get-CimInstance -Namespace root\HP\InstrumentedBIOS -ClassName HP_BIOSEnumeration |
  Where-Object Name -match 'Fan|Thermal|Cool' |
  Select-Object Name, CurrentValue, @{n='Options';e={ $_.Value -join ' | ' }}

# 2. Actual temperature — two independent sources
Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature |
  ForEach-Object { '{0}: {1:N1} C' -f $_.InstanceName, (($_.CurrentTemperature / 10) - 273.15) }
(Get-Counter '\Thermal Zone Information(*)\Temperature').CounterSamples |
  Where-Object { $_.CookedValue -gt 274 } |
  ForEach-Object { '{0}: {1:N1} C' -f $_.InstanceName, ($_.CookedValue - 273.15) }

# 3. Frequency as a share of base — THE deciding measurement
(Get-Counter '\Processor Information(_Total)\% Processor Performance',
             '\Processor Information(_Total)\% Processor Time' -SampleInterval 3 -MaxSamples 3).CounterSamples |
  Select-Object @{n='C';e={($_.Path -split '\\')[-1]}}, @{n='V';e={[math]::Round($_.CookedValue,1)}}

# 4. Power plan
powercfg /getactivescheme
```

**Reading step 3:** `% Processor Performance` is expressed against base clock, so
`100` means base and `150` means the package is sitting 50% above it. Anything
sustained above ~110% while utilization is modest is the turbo case. Confirm it is
package-wide rather than one busy core:

```powershell
(Get-Counter '\Processor Information(*)\% Processor Performance' -SampleInterval 2 -MaxSamples 1).CounterSamples |
  Where-Object InstanceName -notmatch '_total' |
  Select-Object InstanceName, @{n='PctOfBase';e={[math]::Round($_.CookedValue)}} | Sort-Object InstanceName
```

### Disabling turbo when light load holds high clocks

**Do not use the "max processor state 99%" trick.** It disables turbo only on
hardware using legacy OS-driven P-states. On any modern Intel part with Speed Shift
/ HWP the platform owns the P-state and simply ignores it — verified on a 13th-gen
P-series, where the setting applied cleanly (`PROCTHROTTLEMAX` AC = 99) and
frequency stayed at 133–158% of base.

The setting that works is **`PERFBOOSTMODE`**, but it is frequently hidden — and on
some OEM schemes absent entirely, so `powercfg /query` prints nothing for it even by
GUID. Unhide it in the registry first (`Attributes = 2`), then set it:

```powershell
# Elevated. Unhide PERFBOOSTMODE and PERFEPP under SUB_PROCESSOR.
$sub = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00'
Set-ItemProperty "$sub\be337238-0d82-4146-a960-4f3749d470c7" -Name Attributes -Value 2   # PERFBOOSTMODE
Set-ItemProperty "$sub\36687f9e-e3a5-4dbf-b1dc-15eb381c6863" -Name Attributes -Value 2   # PERFEPP

# 0 = Disabled, 1 = Enabled, 2 = Aggressive, 3 = Efficient Enabled, 4 = Efficient Aggressive
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR be337238-0d82-4146-a960-4f3749d470c7 0
powercfg /setactive SCHEME_CURRENT
powercfg /query SCHEME_CURRENT SUB_PROCESSOR be337238-0d82-4146-a960-4f3749d470c7 | Select-String 'Current AC'
```

Revert with `1` in place of `0`, then `/setactive` again. `setacvalueindex` only
touches AC; use `setdcvalueindex` if the same behaviour is wanted on battery.

Measured effect on a 13th-gen i7 P-series with ~20% sustained background load:

| | before | after |
|---|---|---|
| `% Processor Performance` | 133–167% | 94–95% |
| CPU thermal zone | 71.9 °C | 60–63 °C |

**Expect reported CPU% to go up, not down** — in that run, 13–27% became 24–31%.
That is not a regression: the same work occupies a larger share of a slower clock.
Judge the change on temperature, not on utilization. The cost is real, though —
peak burst speed is capped at base clock, so builds and test runs get slower. It is
a trade, not a free win.

If temperature drops but the fan stays on, you have **both** causes: go back and
reduce sustained background load as well.

## Gotchas

- **`% Processor Performance` and `Processor Frequency` disagree — trust the former.**
  The `Processor Frequency` counter frequently reports base clock regardless of
  actual boost state (observed reading ~2.1 GHz while the package was genuinely at
  ~3.3 GHz). `Win32_Processor.CurrentClockSpeed` is unreliable in the same way, often
  simply echoing `MaxClockSpeed`.
- **Cutting CPU% without moving temperature is itself a finding.** If killing a heavy
  process drops total utilization several points and the thermal zone does not
  follow, utilization was never the driver — check frequency before hunting the next
  process.
- **Thermal zone instance names contain a backslash** (`\_tz.cpuz`), which breaks
  counter-path parsing if embedded directly: `'\Thermal Zone Information(\_tz.cpuz)\Temperature'`
  fails with `PDH_CSTATUS_NO_OBJECT` (`c0000bb8`). Enumerate with `(*)` and filter on
  `InstanceName` instead.
- **ACPI thermal zones are coarse and slow.** `MSAcpi_ThermalZoneTemperature` updates
  on a slow polling interval and reports in 0.1K steps, so an identical reading across
  several samples is normal and does **not** prove a stuck sensor. Cross-check against
  `\Thermal Zone Information(*)\Temperature` before drawing conclusions. Many zones on
  a given board are unimplemented stubs that read a constant (often ~30°C or ~0°C) —
  ignore those rather than treating them as real.
- **A warm charger zone is not proof of charging.** `\_tz.chgz` can sit above 50°C on
  a fully-charged machine on AC. Confirm with `ChargeRate` from
  `Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus` before treating the
  battery as a heat source; `0` means it is passive warmth, not charging.
- **Virtual display drivers keep working with no client attached.** A leftover virtual
  adapter (spacedesk and similar) continues capturing and encoding a desktop
  indefinitely, costing both service CPU and kernel time. `[System.Windows.Forms.Screen]::AllScreens`
  reveals displays that `WmiMonitorID` does not, since the latter lists only physical
  panels. Cross-check against `Get-CimInstance Win32_VideoController`.
- **Your own WMI polling shows up in the results.** Repeated `Get-CimInstance` calls
  drive `WmiPrvSE` to a few percent. Discount it rather than reporting it as a finding.
- **Browser auto-launch keys come back.** Edge (and Chrome) recreate
  `MicrosoftEdgeAutoLaunch_*` / `GoogleChromeAutoLaunch_*` on update or on certain
  launches — observed reappearing within hours of removal. The script is idempotent
  precisely because it is worth re-running; treat these entries as recurring, not
  fixed once.
- Audio APO services (`SNAPOService`) are safe to disable even when using Bluetooth —
  APO only affects the laptop's built-in audio pipeline.
- To re-enable a service: `Set-Service -Name <name> -StartupType Automatic; Start-Service <name>`
- To identify which service is inside a high-CPU `svchost`: `tasklist /svc /fi "pid eq <pid>"`
- Intel Analytics is resolved automatically by DisplayName pattern — no manual action
  needed if the service is not present on a given machine.
- Both `HKCU` and `HKLM` startup entries are checked. `HKLM` writes are allowed because
  the script already enforces admin elevation.
- Perf-counter process names are **not** PIDs and collide: `chrome#13` is an arbitrary
  instance index that can change between samples. Join on `IDProcess` when you need to
  follow one process across samples.
