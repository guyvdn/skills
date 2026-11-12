---
name: windows-edge-profile-pins
description: 'Use this skill only when the user explicitly asks about Microsoft Edge profile icons on the Windows taskbar: a pinned Edge icon for one profile that opens another profile (usually the last one used), wanting a separate taskbar icon per Edge profile, or a profile pin that lost its avatar badge.'
version: 1.0.0
---

# Edge profile pins on the Windows taskbar

One taskbar icon per Edge profile, each opening its own profile and showing its avatar badge.

```powershell
# Show the profiles: folder (Default, Profile 1, ...), display name, icon present
pwsh -File scripts/New-EdgeProfileShortcuts.ps1 -List

# Write "Edge - <name>.lnk" to the desktop for every profile
pwsh -File scripts/New-EdgeProfileShortcuts.ps1
```

Then the **user** pins them. Windows has no supported pin API, so:

1. Unpin the existing Edge icons.
2. Drag each desktop shortcut onto the taskbar, **or** Shift + right-click it > **Pin to taskbar**.
   The Windows 11 context menu may have neither *Pin to taskbar* nor *Show more options*;
   Shift + right-click always opens the classic menu.
3. Close every Edge window of that profile and click the pin to test. While a window of that
   profile is open, clicking the pin only switches to it, which proves nothing.
4. The desktop shortcuts can go. Pinning copies the `.lnk` into
   `%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar`.

## Diagnose first

Read what the pins actually point at before changing anything:

```powershell
$sh = New-Object -ComObject WScript.Shell; $app = New-Object -ComObject Shell.Application
$root = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned"
Get-ChildItem $root -Recurse -Filter *.lnk | Where-Object Name -match 'Edge' | ForEach-Object {
  $l = $sh.CreateShortcut($_.FullName)
  $aumid = $app.Namespace($_.DirectoryName).ParseName($_.Name).ExtendedProperty('System.AppUserModel.ID')
  "{0}`n  {1}`n  icon={2}  aumid={3}" -f $_.FullName, $l.Arguments, $l.IconLocation, $aumid
}
```

- `TaskBar\*.lnk` are real pins. `ImplicitAppShortcuts\<hash>\*.lnk` are shortcuts Windows
  created for a running Edge profile window; the icon can sit on the taskbar without being a
  pin in `TaskBar\`.
- Edge gives each profile its own taskbar group ID: `MSEdge` for `Default`,
  `MSEdge.UserData.Profile1` for `Profile 1`, and so on. Windows groups windows under a pin
  by that ID.
- The profile folder name is not the display name: the folder `Profile 1` can be named
  anything. Read `Local State` (`profile.info_cache`); it needs `ConvertFrom-Json -AsHashtable`
  because it contains a property with an empty name. Use `shortcut_name`, which is what Edge's
  settings page shows. `name` can still hold a stale default such as "Profile 1" on the
  `Default` folder.

## What was seen, and what was not proven

Case where both Edge pins opened the last-used profile: the Default pin was a real `TaskBar`
shortcut with `--profile-directory=Default`. The second profile's icon existed only as an
`ImplicitAppShortcuts` entry, with correct arguments. Edge had been started through a file
association (`--single-argument <file>`), with no profile argument. Replacing both icons with
fresh `.lnk` pins made from explicit shortcuts fixed it.

**Not proven:** *why* the old icons ignored their arguments. The likely cause is that Windows
started them from the group ID instead of the shortcut. `MSEdge` then resolves to the Start
menu Edge shortcut, which has no `--profile-directory`, and Edge opens the last-used profile.
Treat this as an unconfirmed theory, not a fact.

## Gotchas

- **Edge may not offer "Create desktop shortcut".** It is missing from `edge://settings/profiles`
  in recent and organisation-managed Edge builds. That is why the script exists.
- **A shortcut made with `WScript.Shell` shows the plain Edge logo** unless `IconLocation`
  points at `<User Data>\<profile folder>\Edge Profile.ico`. Edge writes that file itself; the
  script uses it when present. After changing the icon on an existing pin, run
  `ie4uinit.exe -show`. If the taskbar still shows the old icon, restart Windows Explorer.
