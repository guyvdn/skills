# Gotchas

Part of the [windows-perf](../SKILL.md) skill. Counter, sensor and tooling traps that
produce a wrong reading or a wrong conclusion.

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
