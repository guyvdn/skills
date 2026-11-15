# Everspace 2

Tuned 2026-11-09 on game version 1.5.57528 (Steam), RTX 5070 Ti, 3440×1440 BenQ EX3501R.
The user confirmed it looked better afterwards.

- Engine: Unreal 5, project code name **`ES2`**, exe `ES2\Binaries\Win64\ES2-Win64-Shipping.exe`.
- Config: `%LOCALAPPDATA%\ES2\Saved\Config\Windows\GameUserSettings.ini` (CRLF, ASCII).
- No `ES2.log` is written. `Saved\Logs` only holds joystick and keybinding logs.
- Ships DLSS 310.6 (`nvngx_dlss`, `nvngx_dlssd` = ray reconstruction, `nvngx_dlssg`),
  Streamline 2.11, XeSS 2.0.2 and FSR 4 DLLs.

## Keys that matter

`[/Script/ES2Upscalers.UpscalerConfig]`, stored **by name**:

| Key | Values (from the exe) | Set |
|---|---|---|
| `Upscaler` | Off, DLSS, FSR1, FSR2, FSR3, XeSS, Builtin | `DLSS` |
| `QualityMode` | Off, Auto, AntiAliasing (= DLAA), UltraQualityPlus, UltraQuality, Quality, Balanced, Performance, UltraPerformance, ScreenPercentage | `AntiAliasing` at first, then `Quality` (fans, 2026-11-15) |
| `RayReconstructionMode` | Off, On | `On` (with Lumen) |
| `FrameGenMode` | Off, On, On3X, On4X, Auto | left `Off` |
| `LatencyReductionMode` | Off, Level1, Level2 | left `Level1` |

`[/Script/ES2.ESGameUserSettings]`:

| Key | Meaning | Set |
|---|---|---|
| `GlobalIllumination` | **numeric**: 0 Off, 1 SSGI, 2 Lumen (exe order, menu check advised) | `2` |
| `bChromaticAberration` | lens colour fringing | `False` |
| `bMotionBlur` | taste | left `True` |
| `bSSGI`, `FSRSetting`, `FSR2Setting`, `DLSSSetting` | legacy, superseded by the keys above | untouched |
| `*Quality=3`, `[ScalabilityGroups] sg.*=3` | Epic presets | already max |
| `sg.GlobalIlluminationQuality` | Lumen quality. The menu has no option for it (only the GI *type*), and the game rewrites it from its preset on exit | tried `2`, reverted to `3` after one session; leave it |
| `bFPSCapEnabled`, `CappedFPS` | frame cap | `True`, `75` (100 Hz monitor) |
| `bUseHDRDisplayOutput` | HDR | left `False` (the EX3501R's HDR is weak) |

## Follow-up 2026-11-15: fans too loud

Lumen Epic plus DLAA at 3440×1440 kept the RTX 5070 Ti near its 300 W limit even at a
60 fps VSync cap. The middle ground that worked: DLSS Quality and a 75 fps cap, with
G-SYNC Compatible on (the user set it for windowed and full screen). Lumen stays at
Epic: the attempt to set it to High didn't stick (see the table). The user called the result "the
perfect mix". The same day the monitor went from 60 to 100 Hz (Windows had offered 100 Hz
over DisplayPort all along).
