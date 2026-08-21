---
name: windows-display-dimming
description: 'Use this skill only when the user explicitly asks why a laptop screen dims or brightens by itself, or asks to turn off adaptive/dynamic/automatic brightness on Windows — covers ambient-light adaptive brightness, content-adaptive dimming (Intel DPST, AMD Vari-Bright, CABC), battery-saver dimming, and making the fix survive Windows feature updates.'
version: 1.0.0
---

# Windows display auto-dimming

Three unrelated mechanisms dim a laptop panel on their own, and users describe all of them
as "dynamic brightness". Identify which one before changing anything — the fix for each is
in a different place, and the most common one is *not* the setting people reach for first.

**Start with the audit.** Read-only, changes nothing.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Test-DisplayDimming.ps1
```

## The three mechanisms

| # | Mechanism | Reacts to | Where it lives |
|---|---|---|---|
| 1 | **Adaptive brightness** | Room light, via an ambient light sensor | `powercfg` `SUB_VIDEO ADAPTBRIGHT` |
| 2 | **Content-adaptive dimming** (CABC / Intel DPST / AMD Vari-Bright) | What is **on screen** — dims on dark content | GPU driver registry |
| 3 | **Battery-saver dimming** | Unplugging | `powercfg` `SUB_ENERGYSAVER ESBRIGHTNESS` |

The distinguishing question: **does it change when you switch between a dark and a light
window, with the room light constant?** If yes it is #2, and turning off "adaptive
brightness" will do nothing — that setting only governs #1. Most reports land here.

#2 is also the one that looks like a *contrast* change rather than a brightness change,
because the driver raises pixel values as it drops the backlight to disguise the dimming.

## Fixing it

Supported UI paths first — they apply immediately and survive driver updates:

- **#1** — Settings → System → Power & battery → *Screen brightness* → uncheck *Change
  brightness automatically when lighting changes*
- **#2** — Settings → System → Display → **Brightness** → *Change brightness based on
  content* → **Off**. Not "On battery only". On Intel also check **Intel Arc Control /
  Graphics Command Center → System → Power → Display Power Savings**, which has
  **separate toggles for Plugged In and On Battery** — missing the second one is the usual
  reason "I already turned it off" is wrong.
- **#3** — Settings → System → Power & battery → Energy saver → *Lower screen brightness*

Then the script, which enforces #1 and #2 and is idempotent:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Disable-AdaptiveDimming.ps1 -RestartAdapter
```

### The registry values

Intel DPST, under the display class key
`HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\<NNNN>`:

| Value | Meaning | Want |
|---|---|---|
| `PowerDpstAggressivenessLevel` | `REG_BINARY`, first byte 0–6 | `00 00 00 00` |
| `Dpst6_3ApplyExtraDimming` | `REG_DWORD` extra dimming pass | `0` |

AMD equivalent: `PP_VariBrightEnableDefault` = `0`.

**Do not hardcode subkey `0000`.** The index changes when a driver package is re-staged,
which is exactly the situation these scripts exist for. Match on `DriverDesc` instead.

`FeatureTestControl = 0x8000` is the old advice for this and is obsolete — it does nothing
on modern Xe/Arc drivers.

## Changes only apply when the driver reloads

The driver reads these values at init, so a registry write does nothing until the next
driver load. `-RestartAdapter` forces it now via `pnputil /restart-device` (the screen
blanks for a second); otherwise it takes effect at the next boot.

## Making it stick across feature updates

**A Windows feature update re-stages the graphics driver package and resets its power
policy.** This is the usual answer to "it came back" or "this started last week and I
changed nothing" — it is not a setting the user touched. On the Insider channels it
recurs every few weeks.

Confirm the timing before blaming anything else:

```powershell
# feature-update window
Get-ChildItem C:\Windows\Panther\setupact.log | Select-Object LastWriteTime
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallDate  # unix seconds

# when the driver package was staged
Get-ChildItem C:\Windows\System32\DriverStore\FileRepository -Filter 'iigd*' -Directory |
    Select-Object Name, CreationTime

# Insider channel - if set, expect this to recur
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability' |
    Select-Object BranchName, EnablePreviewBuilds
```

Note that a feature update often keeps the **same driver version** while still resetting
the values, so comparing version numbers will not reveal it — compare DriverStore folder
`CreationTime` instead.

Install the self-healing task:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Disable-AdaptiveDimming.ps1 -InstallTask
powershell -ExecutionPolicy Bypass -File scripts/Disable-AdaptiveDimming.ps1 -UninstallTask
```

It copies the script to `%ProgramData%\AdaptiveDimmingFix` and registers a **SYSTEM** task
at boot with a 1-minute delay. Deploying outside the repo is deliberate: a boot task must
not depend on a working copy that can be moved or deleted.

Two settings matter on a laptop and are **not** the defaults —
`-AllowStartIfOnBatteries` and `-DontStopIfGoingOnBatteries`. Without them the task is
skipped on battery, which is when the dimming is most noticeable.

The task deliberately does **not** restart the adapter: at boot the driver has already
read the registry, so a restart there would be a pointless screen flash. After an update
wipes the settings you get one boot of dimming, then it self-heals.

## Verifying

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Test-DisplayDimming.ps1
Get-Content $env:ProgramData\AdaptiveDimmingFix\adaptive-dimming.log -Tail 10
Get-ScheduledTaskInfo -TaskName 'Disable Adaptive Dimming' | Select-Object LastRunTime, LastTaskResult
```

`LastTaskResult` must be `0`. Run the task once by hand after installing — running as
SYSTEM is not the same as running as the signed-in user, and a task that only fails at
boot is easy to miss.

## Gotchas

- **`powercfg -query` exits 0 and prints only the scheme header when a setting is hidden**
  on the active scheme. Check that the output actually matched; do not trust `$LASTEXITCODE`.
- Vendor power utilities (HP Power Manager, Lenovo Vantage, Dell Power Manager) layer their
  own profiles on top and can re-enable dimming when the user switches profile. If the
  setting reverts without an OS update, look there.
- `$matches` is a PowerShell automatic variable populated by `-match`. Do not use it as a
  local flag name in a scope that also uses `-match`.
