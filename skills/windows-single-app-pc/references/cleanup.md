# Cleaning a family laptop down to one app

## Uninstalling silently

Read `UninstallString` / `QuietUninstallString` from the three Uninstall keys
(`HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*`, the `WOW6432Node` twin,
`HKCU:\…\Uninstall\*`), stop the app's processes first, then run each with a timeout so one
hanging uninstaller can't block the rest (`Start-Process … -PassThru` + `WaitForExit(300000)`).

| Installer type | Silent switch |
|---|---|
| MSI (`MsiExec.exe /I{GUID}` or `/X{GUID}`) | `msiexec /x {GUID} /qn /norestart` |
| NSIS (`uninstall.exe`, Steam, Synthesia, TeamViewer) | `/S` |
| Inno Setup (`unins000.exe`) | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` |
| Chromium-style (`setup.exe --uninstall`, Copilot) | add `--force-uninstall` |
| OneDrive (per user) | `%LOCALAPPDATA%\Microsoft\OneDrive\<ver>\OneDriveSetup.exe /uninstall /silent`, from an **elevated** session |
| Store apps | `Get-AppxPackage -AllUsers -Name <n> \| Remove-AppxPackage -AllUsers`, plus `Remove-AppxProvisionedPackage -Online` |

**Exit codes lie both ways; check the folder and the Uninstall key afterwards:**

- `1605` (unknown product) usually means the entry is stale: the files are already gone.
  Delete the leftover Uninstall key once the install folder is confirmed missing.
- `3010` = done, restart needed (Google Drive left an empty folder until the restart).
- Overwolf's uninstaller returned 0 from an SSH session and removed nothing; delete its
  folder, its Run entry and its updater task by hand.
- Steam's uninstaller removes the games under `steamapps` too; Epic's leaves its games
  (`C:\Program Files\Epic Games\<game>`) behind.
- An uninstaller that wants elevation raises a UAC prompt in the user's session and waits
  forever. Run it from an elevated session instead; never kill `consent.exe`.

## Background work worth switching off

- Search indexing (`WSearch`): on an old laptop it was the second-largest CPU user after
  Defender. Start-menu search still works unindexed.
- Telemetry: `AllowTelemetry=1` (`HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection`),
  `DiagTrack` and `dmwappushservice` disabled.
- Policies: `CloudContent\DisableWindowsConsumerFeatures=1`, `DisableSoftLanding=1`,
  `AppPrivacy\LetAppsRunInBackground=2`, `GameDVR\AllowGameDVR=0`,
  `WindowsUpdate\AU\NoAutoRebootWithLoggedOnUsers=1` (no restart mid-job),
  `DeliveryOptimization\DODownloadMode=0`, Edge `StartupBoostEnabled=0` and
  `BackgroundModeEnabled=0` (and delete its `MicrosoftEdgeAutoLaunch_*` Run value).
- Defender stays on: `Set-MpPreference -EnableLowCpuPriority $true -ScanAvgCPULoadFactor 25`.
- Some keys refuse even an admin (24H2 protected `Policies\Microsoft\Dsh` for widgets;
  removing `MicrosoftWindows.Client.WebExperience` removes widgets anyway), and the
  per-user `\SoftLanding\<SID>\` tasks deny disabling (the policy covers them).

## OEM scheduled tasks: disable selectively

Vantage telemetry and "Smart Performance" tasks (`\Lenovo\Vantage\Schedule\*`) can go.
**Keep `\Lenovo\Power Manager\*` and `\Lenovo\UDC\*`**: Power Manager applies the battery
charge thresholds (see the `thinkpad-charge-limit` skill). Lenovo System Update can stay
installed with its `\TVT\` tasks disabled and be run by hand.

## OneDrive with redirected Desktop / Documents / Pictures

When Known Folder Move is on (`HKCU:\…\Explorer\User Shell Folders` → `Desktop` =
`…\OneDrive\Desktop`), uninstalling OneDrive leaves those folders pointing into a dead sync
root full of placeholders. In this order:

1. **Copy the app's project files to the network share first**, from a task in the user's
   desktop session: reading a cloud-only file there makes OneDrive download it. Also check
   `Documents\<App> Projects`-style folders and Downloads; the app's config often records
   the last folder (`DefaultOpenSavePath`).
2. **Copy, never move, the locally stored files** of the redirected folders to
   `%USERPROFILE%\Desktop|Documents|Pictures`. Skip placeholders: attributes `0x400000`
   (RECALL_ON_DATA_ACCESS) or `0x1000` (OFFLINE). Moving a file out of a synced folder
   deletes it in the cloud.
3. Point `Desktop`, `Personal`, `My Pictures` and their GUID twins
   (`{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}`, `{F42EE2D3-909F-4907-8871-4C22FC0BF756}`,
   `{0DDD015D-B06C-45D5-8C4C-F59713854639}`, only where present) back to
   `%USERPROFILE%\…` as `REG_EXPAND_SZ`, then restart Explorer.
4. Uninstall OneDrive for that user only (other accounts keep theirs).
5. Delete the old `OneDrive` folder only after checking that OneDrive isn't running and no
   `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager\OneDrive*<SID>*`
   key remains. With no client, deleting placeholders cannot reach the cloud; 51,000 of them
   went in four seconds.

## Other people's accounts

- **Measure, then look, then ask.** `robocopy C:\Users\<u> NUL /L /S /NFL /NDL /NJH /BYTES /XJ`
  is fast where `Get-ChildItem -Recurse` takes many minutes. List the newest items in
  Desktop, Documents, Downloads and OneDrive. OneDrive content is in the cloud; **Downloads
  is local only**, and on a family laptop it held medical documents and school work.
  Report what you found and let the user check with the people concerned.
- `LastLogon` is empty for Microsoft accounts and a profile's `LastUseTime` is bumped by
  Windows itself at boot; neither proves the account is unused.
- Delete with `Get-CimInstance Win32_UserProfile | ? LocalPath -eq 'C:\Users\<u>' |
  Remove-CimInstance` (folder and registry entry; the profile must not be loaded), then
  `Remove-LocalUser <u>`. About 26 GB took over ten minutes on an old laptop; run it in the
  background.
- Keep one local admin account as a fallback in case the Microsoft-account login breaks.
