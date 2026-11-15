---
name: pc-game-graphics
description: 'Use this skill when the user asks to improve, tune or configure the graphics or image quality of a PC game on Windows ("the graphics can be better", "make it look sharper", "best settings for my GPU", "enable DLSS/DLAA", "set up Lumen") — finds the game''s config file, backs it up, works out which values the game accepts (Unreal Engine enums read from the exe), edits it with the game closed, and reports each change with the reason it improves the picture. Not for FPS troubleshooting of a game that runs badly, driver installs, or console games.'
version: 1.0.0
---

# PC game graphics tuning

Most "the graphics could be better" complaints are not about the quality presets. Those are
often already maxed. The visible wins are almost always in four places: **anti-aliasing /
upscaler mode, global illumination method, lens-effect post-processing, and the display
mode Windows is driving**. Edit the game's config file rather than describing menus, but
only after a backup and with the game closed.

## Workflow

- [ ] 1. **Audit (read-only).** Run:
  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts/Find-GameConfig.ps1 -Name '<Full name>|<CodeName>'
  ```
  It prints the install folder, engine, shipped upscaler DLLs and versions, config file
  candidates, GPUs, each monitor's connection type and the refresh rates Windows offers it,
  and whether the game
  is running. Unreal config folders use the **project code name**, not the store name
  (Everspace 2 → `ES2`). If nothing matches, rerun with the project folder name it printed.
- [ ] 2. **Read the whole config** before deciding anything. Note what is already maxed so you
  don't "improve" it.
- [ ] 3. **Learn the valid values.** For Unreal games, run
  `scripts/Get-UEEnums.ps1 -Exe <shipping exe> -Pattern '<key names>'` (about 1 s). It lists
  the names the game's enums accept (`EUpscaler::DLSS`, `EUpscalerQualityMode::AntiAliasing`).
  Read *Gotchas* before you turn a name into a number.
- [ ] 4. **Close the game, back up the config folder** next to itself with a date suffix:
  `Copy-Item <...>\Saved\Config <...>\Saved\Config-backup-YYYY-MM-DD -Recurse`.
- [ ] 5. **Edit** only the keys you are changing (see *What to change*). Use PowerShell or the
  Edit tool, not Git Bash `sed -i`.
- [ ] 6. **Verify** with a line diff against the backup. Expect only your changed lines:
  `Compare-Object (Get-Content $backup) (Get-Content $file)`. Also check the line endings
  match the backup.
- [ ] 7. **Report**: a before / after / why table, what to confirm in the game's menu (every
  numeric value you inferred), the fallback if FPS drops, what you deliberately left alone,
  and any display-level problem (step 1). Give the backup path and the one-line restore.

## What to change, in order of visible impact

| Area | Do | Why it shows |
|---|---|---|
| Anti-aliasing / upscaler | NVIDIA RTX: **DLSS in DLAA mode** (often called `AntiAliasing` or `DLAA`). Fallback, when the GPU can't hold the frame rate: DLSS Quality. Without DLSS: XeSS / FSR native-AA mode, then TSR, then TAA | Full-resolution input, so no detail is lost. Far less shimmer and ghosting than TAA. `nvngx_dlss.dll` 310.x or newer = DLSS 4 transformer model |
| Global illumination | UE5: **Lumen** over SSGI | SSGI only sees what is on screen, so lighting pops at the edges and when you turn |
| Ray reconstruction | **On** when Lumen or RT is on and `nvngx_dlssd.dll` ships | Replaces the blurry denoiser, so reflections and bounce light stay sharp |
| Chromatic aberration, film grain, vignette | **Off** | Fake lens flaws: colour fringes and noise. Worst on ultrawide edges |
| Quality presets | Leave at Epic (3). Try Cinematic (4) only if the game exposes it | Usually already maxed. Many games clamp or reset 4 |

Usually leave alone, and say why in the report:
- **Motion blur**: a matter of taste. It helps at 60 Hz and hides detail at high refresh rates.
- **Frame generation**: smoother, not sharper, and it adds latency. Never at a 60 Hz cap.
- **HDR**: only on a monitor with real HDR (local dimming or OLED, roughly 600+ nits). On a
  "HDR10 / HDR400" panel with no local dimming it looks washed out.
- **Dynamic resolution**: keep it off when using DLAA. It undoes the point.
- Gamma, FOV and controls: not image quality.

## Loud fans: the middle ground

Maxing image quality loads the GPU to its power limit, even when VSync caps the frame rate
(the work per frame goes up). If the user then finds the fans too loud, cut in this order.
Each step costs less picture than the next:

1. **DLAA → DLSS Quality.** About 45% of the pixels, roughly a third less GPU work. With
   the DLSS 4 transformer model the difference is hard to see at 1440p and above.
2. **GI / Lumen quality Epic → High** (`sg.GlobalIlluminationQuality=2`). Lumen stays on.
   The game may rewrite `sg.*` from its own menu settings, so re-read the ini after one
   session to see if it stuck.
3. **A frame cap a little below the refresh rate** (e.g. 75 on a 100 Hz panel with
   G-SYNC/FreeSync). Smoother than 60, and the GPU doesn't chase 100.
4. Outside the game: a GPU power limit around 80% (`nvidia-smi -pl`, admin, resets at
   reboot) costs about 5% performance with much less heat. Offer it, don't apply it unasked.

## Gotchas

- **The game rewrites its config on exit.** Edit while it runs and your changes are lost.
  The audit flags a running process.
- **Git Bash `sed -i` turns CRLF into LF.** The diff then shows every line changed. UE reads
  either, but restore CRLF to keep the file as the game wrote it:
  ```powershell
  [IO.File]::WriteAllText($f, ([IO.File]::ReadAllText($f) -replace "`r?`n", "`r`n"), [Text.Encoding]::ASCII)
  ```
- **Enum order in the exe is not reliable.** `Get-UEEnums.ps1` gives the exact *names*, but
  the byte order is only a hint at the *number*. UE's own `EDynamicGlobalIlluminationMethod`
  is stored in reverse. Prefer keys stored by name (`Upscaler=DLSS`). For numeric keys
  (`GlobalIllumination=2`), say it's inferred and have the user check the menu.
- **`::Type` is not a value.** It's UE's `namespace EFoo { enum Type }` pattern. `Count`,
  `MAX` and `Num` are sentinels.
- **Legacy keys stay in the file.** An old flag can contradict the real setting (Everspace 2
  keeps `bSSGI=False` next to `GlobalIllumination=1` = SSGI, and `DLSSSetting=-1` next to the
  newer `[...UpscalerConfig]` section). Change the key the current menu writes. The
  section holding the newest settings is usually the right one.
- **Config path differs by engine version**: UE5 uses `Saved\Config\Windows\`, UE4 uses
  `Saved\Config\WindowsNoEditor\`. Unity uses `HKCU:\Software\<Company>\<Product>` (values
  stored as `Name_h<hash>` DWORDs) or `AppData\LocalLow`. Other games use
  `Documents\My Games` or `Saved Games`.
- **Steam Cloud may sync config files.** If a change reverts on launch, look under
  `Steam\userdata\<id>\<appid>\remote`.
- **Windows can run the monitor below its rated refresh rate.** A 100 Hz panel on
  DisplayPort sat at 60 Hz for months. The audit's *Displays* section shows the connection
  type, the current rate and every rate Windows offers at that resolution, and flags a
  monitor running below the highest one. Judge by that list only. `WmiMonitorListedSupportedSourceModes`
  reads only the EDID's base block, misses high-refresh timings stored in extension blocks
  (it listed 60 Hz only for that same monitor), and led to a wrong "your cable is the
  limit" diagnosis. Blame the cable/port only when the rated refresh is missing from the
  offered list. Report it, and change the display mode only after the user agrees.
  Switching it raises the frame rate VSync allows, and so the GPU load and fan noise
  (see *Loud fans*).
- **Game logs may not exist.** Shipping builds often write no `<Project>.log`, so you can't
  read the active RHI or upscaler from logs. The DLLs and the exe are the evidence.

## Per-game notes

Before editing a game listed here, read its file. Add one after each new game.

- Everspace 2 (UE5, v1.5): `references/everspace-2.md`
