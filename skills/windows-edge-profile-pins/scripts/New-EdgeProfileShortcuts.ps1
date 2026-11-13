<#
.SYNOPSIS
  Create one desktop shortcut per Microsoft Edge profile, ready to pin to the taskbar.

.DESCRIPTION
  Reads the profiles from Edge's "Local State", then writes "Edge - <profile name>.lnk" to the
  desktop for each one. Each shortcut passes --profile-directory and uses the profile's own
  "Edge Profile.ico" (its avatar badge) when Edge has generated one. Existing shortcuts with the
  same name are overwritten. Nothing is pinned: Windows has no supported API for that, so the
  user drags each shortcut onto the taskbar (or Shift + right-click > Pin to taskbar).

.PARAMETER List
  Only list the profiles (folder, name, icon present) and write nothing.

.PARAMETER Name
  Only write shortcuts for profiles whose display name or folder matches (wildcards allowed).
  Use it after adding one profile, so existing desktop shortcuts are left alone.
#>
[CmdletBinding()]
param([switch]$List, [string]$Name = '*')

$userData = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
$exe = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { throw 'msedge.exe not found.' }

# Local State holds a property with an empty name, which plain ConvertFrom-Json rejects.
$state = Get-Content (Join-Path $userData 'Local State') -Raw | ConvertFrom-Json -AsHashtable
$profiles = foreach ($p in $state.profile.info_cache.GetEnumerator()) {
    $ico = Join-Path $userData "$($p.Key)\Edge Profile.ico"
    [pscustomobject]@{
        Folder = $p.Key
        # shortcut_name is what Edge's settings page shows; name can be a stale default.
        Name   = if ($p.Value.shortcut_name) { $p.Value.shortcut_name } else { $p.Value.name }
        Icon   = if (Test-Path $ico) { $ico } else { $null }
    }
}
$profiles = @($profiles | Where-Object { $_.Name -like $Name -or $_.Folder -like $Name })
if (-not $profiles) { throw "No Edge profile matches '$Name'." }

if ($List) { $profiles | Format-Table -AutoSize; return }

$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
foreach ($p in $profiles) {
    $safe = ($p.Name -replace '[\\/:*?"<>|]', '_')
    $path = Join-Path $desktop "Edge - $safe.lnk"
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = $exe
    $lnk.Arguments = "--profile-directory=`"$($p.Folder)`""
    $lnk.IconLocation = if ($p.Icon) { "$($p.Icon),0" } else { "$exe,0" }
    $lnk.Save()
    $path
}
