# Apps that keep starting — make them on-demand

Part of the [windows-perf](../SKILL.md) skill. For an app that still starts at boot after
it was switched off in Settings ▸ Apps ▸ Startup, and that is needed only occasionally.

## Find what actually launches it

Startup Apps only controls the `Run` keys and the Startup folder. If the app still starts,
something else launches it — usually a vendor service or watchdog. Ask the process tree:

```powershell
Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -match '<Vendor>' } | ForEach-Object {
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)"
  [pscustomobject]@{ Name = $_.Name; Pid = $_.ProcessId; Parent = "$($p.Name) ($($_.ParentProcessId))" }
} | Format-Table -AutoSize
```

A parent other than `explorer.exe` (or `sihost`/`RuntimeBroker`) means a service started it, so the Run key
is irrelevant. To check whether a Run entry is disabled, read
`...\Explorer\StartupApproved\Run` (or `Run32`): an odd first byte (`01`, `03`, `05`) =
disabled, an even one (`02`, `06`) = enabled. The remaining bytes are the time it was disabled.

## Fix: services to Manual, plus a launcher

Set the vendor services to **Manual**, not Disabled, so the launcher can still start them.
Stop the **watchdog first**. Otherwise it restarts the main service, which is also
configured to restart on failure.

A start/stop script with one `sudo` call per action gives one UAC prompt per use. Put the
script in `$HOME\bin`. Add two Start-menu shortcuts that run `pwsh -NoProfile -WindowStyle
Minimized -ExecutionPolicy Bypass -File <script> [-Stop]`, with the vendor exe as the icon.
Start the GUI **unelevated** after the services are up.

## Check Point Endpoint Security VPN

Symptom: the tray app keeps starting, and a smart-card / Belgian eID PIN prompt appears
at every boot.

| Component | Role |
|---|---|
| `EPWD` service (`Watchdog\EPWD.exe`) | Watchdog. **Launches `TrGUI.exe`**, the tray app, into the user session. |
| `TracSrvWrapper` service | The VPN service. Spawns `TracCAPI.exe`, the certificate-store helper that **raises the eID prompt**. |
| `HKLM\...\WOW6432Node\...\Run` → `Check Point Endpoint Security VPN` | Run key for `TrGUI.exe`. Disabling it in Startup Apps does nothing, because `EPWD` launches the GUI anyway. |

Fix (elevated):

```powershell
sc.exe config EPWD start= demand; sc.exe config TracSrvWrapper start= demand
Stop-Service EPWD -Force; Stop-Service TracSrvWrapper -Force
Get-Process TrGUI,TracCAPI -ErrorAction SilentlyContinue | Stop-Process -Force
```

Launcher: [scripts/CheckPointVpn.ps1](../scripts/CheckPointVpn.ps1) (`-Stop` to stop).
Revert with `start= auto` on both services.

Traps:

- **`trac.exe info` hangs indefinitely**, so don't use it to check whether the VPN is
  connected. Check the adapter instead:
  `Get-NetAdapter | ? InterfaceDescription -match 'Check Point'`. `Disconnected` is safe to stop.
- **`TracSrvWrapper` takes ~45 s to stop.** `Stop-Service` prints a "Waiting for
  service…" warning for that long. It is not hung.
- **Services started once stay running through sleep, hibernate *and* a Fast Startup
  "shut down", and the watchdog reopens the GUI on every wake, so the eID prompt looks
  like a "startup" again.** Fast Startup (`HKLM\SYSTEM\CurrentControlSet\Control\Session
  Manager\Power\HiberbootEnabled = 1`) hibernates session 0, so services survive a
  shutdown. Check `Kernel-Boot` event 27 in the System log: boot type `0x1` = restored
  from Fast Startup, `0x0` = cold boot. `LastBootUpTime` only moves on a cold boot or a
  Restart. Fix: set `HiberbootEnabled` to `0` (elevated), so every shutdown is a real one.
  Before blaming the start type, check it is still `Manual` and compare when the process
  was created with `LastBootUpTime`. To see who launched it,
  read the UserAssist key (`HKCU\...\Explorer\UserAssist\{GUID}\Count`, ROT13-encoded
  names, last-run FILETIME at byte offset 60); it records Start-menu shortcut launches.
- **A Check Point update or reinstall may set the services back to Auto.** If the eID
  prompt returns after an update, reapply the fix.
