---
name: windows-screen-off
description: 'Use this skill only when the user explicitly asks to turn off the monitor(s) / screen(s) on Windows on demand — a keyboard shortcut, hotkey or one-off command that blanks every display without locking, sleeping or changing power settings.'
version: 1.0.0
---

# Windows screen off

Turn every monitor off now, without locking the session or putting the PC to sleep. Any mouse
move or key press wakes them. No admin needed.

```powershell
# Off, once
powershell -ExecutionPolicy Bypass -File scripts/Invoke-ScreenOff.ps1

# Global hotkey (default Ctrl+Alt+O); -Hotkey 'CTRL+ALT+F12' to choose another
powershell -ExecutionPolicy Bypass -File scripts/Install-ScreenOffShortcut.ps1
powershell -ExecutionPolicy Bypass -File scripts/Install-ScreenOffShortcut.ps1 -Uninstall
```

**Don't run `Invoke-ScreenOff.ps1` to "test" it while the user is at the screen** without saying
so first. The user pressing the hotkey is the test.

## How it works

`Invoke-ScreenOff.ps1` broadcasts `WM_SYSCOMMAND` / `SC_MONITORPOWER` with `lParam = 2` (off)
to `HWND_BROADCAST`. Use **`PostMessage`**, not `SendMessage`: a broadcast `SendMessage` waits
for every top-level window to answer, so one hung app hangs the script.

The installer copies the script to `%LOCALAPPDATA%\ScreenOff` and creates `Screen Off.lnk` in
the user's Start Menu with a hotkey. It deploys outside the repo so the shortcut doesn't break
when a working copy moves. It needs no resident process. AutoHotkey would work too, but it
needs one more thing running at login.

## Gotchas

- **The screens come straight back on** if the off message arrives before the hotkey's
  key-up (or the Enter that ran the command). That's why there's a 700 ms delay
  (`-DelayMilliseconds`). Raise it if a slow key release still wakes them.
- **`.lnk` hotkeys only work for shortcuts on the Desktop or in the Start Menu.** The same
  shortcut anywhere else saves fine and never fires.
- **A hotkey already used by another `.lnk` or app wins silently.** If nothing happens,
  pick another combination before debugging the script.
- The hotkey takes about a second: PowerShell has to start and `Add-Type` compiles the
  P/Invoke signature on every run.
- `WScript.Shell` throws on an unknown key name, but accepts a bare key like `O` that would
  fire on every keystroke. The installer's `-Hotkey` validation requires two or more modifiers.
