---
name: windows-single-app-pc
description: 'Use this skill when turning an old Windows laptop into a quiet, dedicated PC for one program, such as a laser cutter, CNC, 3D printer, plotter or vinyl cutter host running Falcon Design Space, LightBurn, LaserGRBL, xTool Creative Space or a slicer. Also use when such a PC must not sleep in the middle of a job, should stay fan-quiet or last longer on battery, should drop OneDrive or Google Drive in favour of a network share, has old family accounts and games to clear out, or needs a vendor app kept up to date that is not in winget or Chocolatey (Qt Installer Framework installers with a maintenancetool.exe).'
version: 1.0.0
compatibility: 'Windows 10/11. Most steps need admin; driving the PC remotely is covered by the windows-ssh-admin skill.'
---

# Windows single-app PC

Turn a spare laptop into the machine that sits next to a laser, CNC or printer and runs
one program: quiet, frugal on battery, never asleep mid-job, no cloud sync clients, files on
a network share, and the one app it exists for kept current.

Drive it remotely with the `windows-ssh-admin` skill if you aren't on it; the snippets here
assume an elevated PowerShell on the PC itself.

## Step 0 — Survey, then ask

Read before changing anything: model, battery wear (`root\wmi BatteryFullChargedCapacity`
vs `BatteryStaticData`), power plans, `Win32_StartupCommand`, installed programs (the three
Uninstall registry keys), Store apps, non-Microsoft scheduled tasks, local users and their
profiles, top CPU processes. Then ask the decisions that are the user's:

- **Other accounts and games on the machine** — uninstall only, or delete the accounts too?
  Measure each profile and look at its Downloads and Desktop first
  ([references/cleanup.md](references/cleanup.md)); a family PC holds files that exist
  nowhere else.
- **How the machine talks to the device** — over **USB the PC streams the job**, so it must
  not sleep or suspend USB mid-cut; over WiFi or with an upload-then-run device, it can
  sleep freely.
- **Mostly on the charger or on battery** — decides the charge limit (on a ThinkPad see the
  `thinkpad-charge-limit` skill) and how aggressive the battery settings can be.

## Step 1 — A quiet power plan

Duplicate *Balanced* (`powercfg /duplicatescheme 381b4222-f694-41f0-9685-ff5bb260df2e`),
name it, and set:

| Setting (`powercfg /set{ac,dc}valueindex <guid> …`) | AC | DC | Why |
|---|---|---|---|
| `SUB_PROCESSOR PERFBOOSTMODE` (unhide with `powercfg /attributes SUB_PROCESSOR PERFBOOSTMODE -ATTRIB_HIDE`) | 0 | 0 | Turbo off is what keeps an older ultrabook's fan quiet; see `windows-perf` → fan-and-thermals for why not "max state 99 %" |
| `SUB_PROCESSOR SYSCOOLPOL` | 0 | 0 | Passive: throttle before spinning the fan up |
| `SUB_VIDEO VIDEOIDLE` | 600 | 180 | Screen off; doesn't affect a running job |
| `SUB_SLEEP STANDBYIDLE` | 0 | 1200 | Never sleep on the charger; on battery the keep-awake helper (Step 2) covers jobs |
| `SUB_SLEEP HIBERNATEIDLE` / `HYBRIDSLEEP` | 0 / 0 | 3600 / 0 | |
| `SUB_SLEEP RTCWAKE` (wake timers) | 2 | 0 | No Windows Update wake-ups in a bag |
| USB selective suspend `2a737441-…\48e6b7a6-50f5-4782-a5d4-53bb8f07e226` | 0 | 0 | **Never suspend the USB serial link to the device** |
| `SUB_PCIEXPRESS ASPM` | 1 | 2 | |
| WiFi power `19cbb8fa-5279-450e-9fac-8a3d5fedd0c1\12bbebe6-58d6-4636-95bb-3217ef867c1a` | 0 | 3 | |
| `SUB_ENERGYSAVER ESBATTTHRESHOLD` | 30 | 30 | |

`powercfg /setactive <guid>`. Closing the lid still sleeps the PC whatever you set here;
tell the user to keep it open during a job.

## Step 2 — Never sleep while the app is open

Windows' idle timer knows nothing about a job streaming over USB, and many maker apps don't
request "system required" themselves. Install a small SYSTEM task that holds that request
whenever the app's process exists:

```powershell
.\scripts\Install-KeepAwake.ps1 -ProcessName FalconDesignSpace   # process name without .exe
```

**Verify it** with the app open: `powercfg /requests` must list
`[PROCESS] \Device\…\powershell.exe` under `SYSTEM:`, and the line must disappear about 30 s
after the app closes. (The first version of this helper used `0x80000001` and silently did
nothing; PowerShell 5.1 reads that literal as a negative Int32.) On AC with "never sleep",
`[DRIVER] Legacy Kernel Caller / Sleep Idle State Disabled` also shows; that's the plan's
setting, not a driver holding the PC awake.

## Step 3 — Debloat, OneDrive, other accounts

Follow [references/cleanup.md](references/cleanup.md): silent-uninstall switches per
installer type, the exit codes that lie, Store apps for all users, background services and
policies worth switching off, which OEM tasks to **keep**, removing OneDrive without losing
files when Desktop/Documents are redirected into it, and deleting old profiles.

## Step 4 — Files on a network share

Put the app's project files on a share (a NAS, or the `ubuntu-home-server` skill's Samba
section) mapped as a drive letter on this PC and on the PC where designs are made. Copy the
existing projects there **while OneDrive still runs** (cloud-only files hydrate on read),
then point the app's default open/save folder at the drive.

## Step 5 — Keep the app current

If the vendor app is in winget, use `winget upgrade` from a logon task and stop here. Many
maker apps aren't, and their updater only opens a download page. For **Qt Installer
Framework** installers (the app folder has `maintenancetool.exe`, `components.xml`,
`installer.dat`), [scripts/Update-QtIfwApp.ps1](scripts/Update-QtIfwApp.ps1) does a
signature-checked silent update with rollback. How to find the version endpoint and download
URL, how to register it as a logon task, and the Falcon Design Space values are in
[references/app-updates.md](references/app-updates.md).

## Optional — UI language

Switching Windows to another display language over SSH, keeping the keyboard layout:

```powershell
Install-Language -Language en-GB -CopyToSettings
Set-SystemPreferredUILanguage -Language en-GB
Set-WinUILanguageOverride -Language en-GB
$l = New-WinUserLanguageList en-GB; $l[0].InputMethodTips.Clear(); $l[0].InputMethodTips.Add('0809:00000813')   # en-GB + Belgian (Period) keyboard
Set-WinUserLanguageList $l -Force
Set-Culture en-BE                     # formats: English names, euro, dd/MM/yyyy (en-GB formats use £)
Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
```

Takes effect at the next sign-in. `Get-Culture` in the same process still shows the old
value; check in a new one.

## Gotchas

- **Don't disable every OEM scheduled task.** On a ThinkPad, `\Lenovo\Power Manager\Background
  monitor` is what applies battery charge thresholds; without it the battery sticks at the
  old limit and Vantage claims a driver is missing (`thinkpad-charge-limit` skill).
- A Windows 11 PC that has been off for months spends its first hour on updates and a full
  Defender scan; judge noise and battery after that, not before.
- An app update can reset the app's own settings or log the user out on first start (Falcon
  1.10.7 emptied its `private.ini`); that's the new version, not the update method.
