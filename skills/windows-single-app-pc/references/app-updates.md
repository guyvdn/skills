# Keeping a vendor app current without winget

## Check the easy routes first

```powershell
winget search "<App name>"; winget search <Vendor>
# Chocolatey, without installing it:
Invoke-RestMethod "https://community.chocolatey.org/api/v2/Search()?searchTerm='<app>'&targetFramework=''&includePrerelease=false"
```

If the app's folder has `maintenancetool.exe`, read `maintenancetool.ini`: the
`DefaultRepositories` value is a base64 URL inside a Qt variant. `file:///C:/Program Files/…/repository/`
means an offline installer with no online update channel, so `maintenancetool.exe update`
cannot help.

## Find the version endpoint and download URL

1. **Where the last installer came from.** Windows stores it in the download's alternate
   data stream: `more < "%USERPROFILE%\Downloads\<installer>.exe:Zone.Identifier"` →
   `HostUrl=…`. Two versions usually reveal the pattern (`…/<ver>/Windows/<App> <ver>.exe`).
2. **What the app's own "check for updates" calls.** The app log often only says
   `checkUpdateAction`; the URL is in the binary. Pull strings from a copy of the exe:
   ```bash
   LC_ALL=C grep -aoE "/(pc|app|api|client)[-a-z]*/[A-Za-z0-9/_.?=%-]+" app.exe | sort -u
   LC_ALL=C grep -aoiE "[A-Za-z_/-]{0,30}(latestVersion|checkUpdate|newVersion|upgrade)[A-Za-z_/-]{0,30}" app.exe | sort -u
   ```
   Combine a path such as `pc-api/pcVersion/latestVersion` with the base URLs found the same
   way, and try a plain `GET`. Only use endpoints that answer without credentials, and only
   read from them.
3. **Check the installer's signature**: `Get-AuthenticodeSignature <installer>`. Pin a
   stable part of the subject (an EV certificate's `SERIALNUMBER=` company number) and note
   the certificate's expiry: the next release will carry a renewed certificate.

## Register the updater

```powershell
$dir = 'C:\ProgramData\<App>Update'
New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item .\scripts\Update-QtIfwApp.ps1 $dir
# It runs elevated, so only SYSTEM and Administrators may change it.
icacls $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX'
# Seed the cache with the installed version's installer, named "<App folder name> <version>.exe": it is the rollback target.

$argLine = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $dir\Update-QtIfwApp.ps1 -AppDir '<AppDir>' -ExeName <exe> -LatestVersionUrl '<url>' -VersionProperty <path> -InstallerUrl '<url with {0}>' -SignerMatch '<subject part>' -CacheDir $dir"
$t = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\<user>"; $t.Delay = 'PT2M'
Register-ScheduledTask -TaskName '<App>Update' -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument $argLine) -Trigger $t `
  -Principal (New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\<user>" -LogonType Interactive -RunLevel Highest) `
  -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1))
```

At logon, not at startup: the installer creates shortcuts for the user it runs as (a SYSTEM
run puts them in the system profile), and a PC used only for jobs is signed into when needed.
Test with `Start-ScheduledTask` and read `update.log`.

## Qt Installer Framework, headless

```text
maintenancetool.exe --confirm-command --accept-messages purge
<installer>.exe --root "C:\Program Files\<App>" --accept-licenses --accept-obligations --accept-messages --confirm-command install
```

- **Options before the command.** `purge --confirm-command` treats the option as a package
  name and then stops at "Do you want to continue?" with *"User input is required but the
  output device is not associated with a terminal"*, exit code 1.
- **`--accept-messages` and `--default-answer` are mutually exclusive**; together they print
  the help and exit 1 without doing anything.
- An IFW installer won't install into a non-empty target folder, so a manual update also
  means uninstalling first; `purge` removes the program folder only, not `%LOCALAPPDATA%`.
- `<installer> --help` and `maintenancetool.exe --version` show the IFW version (4.6.1 here).

## Falcon Design Space (Creality Falcon lasers)

| | |
|---|---|
| Install folder / exe | `C:\Program Files\Falcon Design Space\FalconDesignSpace.exe` (Qt IFW 4.6.1, offline installer) |
| Latest version | `GET https://webapp.craftseek.com/pc-api/pcVersion/latestVersion` → `data.latestVersion` (also release notes); no login |
| Installer | `https://download.craftseek.com/<ver>/Windows/Falcon%20Design%20Space%20<ver>.exe` (~380 MB) |
| Signer | EV certificate, subject contains `SERIALNUMBER=91440300094231378E` (the certificate seen in Nov 2026 expired 2026-11-12, so expect a renewed one) |
| User data | `%LOCALAPPDATA%\Falcon Design Space\conf\falcondesignspace.conf` (`DefaultOpenSavePath`, JSON), `private.ini`, `appsettings.ini` |
| Keep-awake process name | `FalconDesignSpace` |

Neither winget nor Chocolatey carried it (Nov 2026). The 1.9.6 → 1.10.7 update went through
the script above; afterwards the user had to sign in to their Creality account again because
1.10.7 emptied `private.ini` on its first start, two minutes after the install finished.
Expect that on version jumps.
