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
| `QualityMode` | Off, Auto, AntiAliasing (= DLAA), UltraQualityPlus, UltraQuality, Quality, Balanced, Performance, UltraPerformance, ScreenPercentage | `AntiAliasing`; `Quality` if FPS drops |
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
| `bUseHDRDisplayOutput` | HDR | left `False` (the EX3501R's HDR is weak) |
