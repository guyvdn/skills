---
name: thinkpad-charge-limit
description: 'Use this skill when a ThinkPad on Windows stops charging at a fixed level (often 80 %), shows "plugged in, not charging" with the battery below full, when Lenovo Vantage or Commercial Vantage says the battery and power driver is not installed or hides the Battery charge threshold switch, or when asked to set, change or remove ThinkPad battery charge thresholds without Vantage. Also use to tell a charge threshold apart from a USB-C dock that supplies too little power, and after a debloat that disabled Lenovo scheduled tasks.'
version: 1.0.0
compatibility: 'Windows 10/11 ThinkPads with the Lenovo Power Management driver (ibmpmdrv) and the Lenovo Power and Battery driver (powermgr.inf). Verified on an X1 Carbon 5th gen, Windows 11 24H2; other models store the same keys but are not tested. Needs an elevated PowerShell.'
---

# ThinkPad charge limit on Windows

ThinkPads can stop charging at a start/stop threshold (for example start below 75 %, stop
at 80 %) to spare a battery that stays plugged in. The thresholds live in the embedded
controller (EC), so they keep working after the app that set them is gone, and keep
blocking a full charge long after anyone remembers turning them on.

## How the pieces fit

| Piece | Role |
|---|---|
| `HKLM\SOFTWARE\WOW6432Node\Lenovo\PWRMGRV\ConfKeys\Data\<battery-id>` | The desired thresholds: `ChargeStartControl`, `ChargeStartPercentage`, `ChargeStopControl`, `ChargeStopPercentage`. One subkey per battery (the id is the battery's barcode/serial). |
| `PowerMgr.exe` (Lenovo Power Manager backend, from the *Lenovo Power and Battery* driver package, `powermgr.inf`) | Reads those values and **pushes them to the EC**. Vantage and Commercial Vantage talk to it too. |
| Scheduled task `\Lenovo\Power Manager\Background monitor` | Starts `PowerMgr.exe` at every logon (Users group). |
| `IBMPMSVC` (Lenovo PM Service, `ibmpmdrv`) | The low-level driver service. Running it alone does **not** apply the registry values. |

**The trap:** a Windows debloat that disables "all Lenovo scheduled tasks" also disables
`Background monitor`. From then on nothing applies threshold changes, and both Vantage apps
report *"battery and power driver not installed"* and hide the threshold switch, even though
both drivers are installed and healthy. Installing drivers from Lenovo's site, updating the
BIOS or reinstalling Vantage changes nothing until `PowerMgr.exe` runs again.

## Step 1 — Is it a threshold or the charger?

```powershell
$st = Get-CimInstance -Namespace root\wmi BatteryStatus
$full = (Get-CimInstance -Namespace root\wmi BatteryFullChargedCapacity).FullChargedCapacity
'online={0} charging={1} rate={2} mW at {3:N0} %' -f $st.PowerOnline, $st.Charging, $st.ChargeRate, (100 * $st.RemainingCapacity / $full)
```

- `PowerOnline=True`, `Charging=False`, `Discharging=False`, sitting just under a round
  number (79 %) = **threshold**. It holds there on any power source.
- A USB-C dock from another brand (an HP USB-C Dock G5 here) may trigger Windows' "slow
  charger" notice. **Swap to the Lenovo charger for a minute:** if the notice disappears but
  the battery still sits at the same level, the dock is fine and it's the threshold.
- `scripts/Set-ThinkPadChargeThreshold.ps1 -Status` shows the stored thresholds, whether
  `PowerMgr.exe` runs and the state of the Lenovo tasks.

## Step 2 — Set it

Run [scripts/Set-ThinkPadChargeThreshold.ps1](scripts/Set-ThinkPadChargeThreshold.ps1)
elevated (directly, or over SSH: see the `windows-ssh-admin` skill):

```powershell
.\Set-ThinkPadChargeThreshold.ps1 -Status                 # read only
.\Set-ThinkPadChargeThreshold.ps1 -Start 95 -Stop 100     # effectively "charge to full"
.\Set-ThinkPadChargeThreshold.ps1 -Start 75 -Stop 80      # always-plugged, battery-friendly
```

It backs up the battery key(s) to `C:\ProgramData\ThinkPadChargeThreshold\`, writes the
values, enables the `\Lenovo\Power Manager\` and `\Lenovo\UDC\` tasks, restarts
`PowerMgr.exe` through `Background monitor`, and watches the battery for a minute. The EC
picked the change up within 10 seconds of `PowerMgr.exe` starting.

**Ask which the user wants**: a machine that lives on the charger is better off at 75/80;
one used on battery wants the full charge. Someone in the household probably set the old
value on purpose.

## What does not work

- **`ChargeStartControl=0` / `ChargeStopControl=0`** ("thresholds off") was not pushed to the
  EC. Keep both controls at 1 and use 95/100 for a full charge.
- **Restarting `IBMPMSVC`**, replugging the charger and restarting Windows left the EC on the
  old values while `PowerMgr.exe` was not running.
- **Vantage / Commercial Vantage** need `PowerMgr.exe` too; once it runs, the threshold
  switch appears and the "driver not installed" warning goes away. They are not needed to
  set the values; uninstall them again afterwards if the machine should stay lean
  (`LenovoVantageService` may come back with the driver package; leave it).

## Gotchas

- **When debloating a ThinkPad, keep `\Lenovo\Power Manager\*` and `\Lenovo\UDC\*`
  enabled.** Disabling the Vantage telemetry tasks (`\Lenovo\Vantage\Schedule\*`) is fine.
- The `<battery-id>` subkey only exists once Power Manager has seen that battery. With no
  subkey, install the *Lenovo Power and Battery* driver (Lenovo System Update or the support
  site), sign out and in, and check again.
- `HKLM\…\PWRMGRV\Data` also has `ChargeStart*/ChargeStop*` values (all 0 here); they are not
  what `PowerMgr.exe` applies. Change the per-battery key.
- A worn battery reports its real capacity in `BatteryFullChargedCapacity` vs
  `BatteryStaticData.DesignedCapacity`; at about half the design capacity, expect half the
  runtime even at 100 %.
