<#
.SYNOPSIS
    Shared helpers for reading and writing voidtools Everything's settings. Dot-source it.
.DESCRIPTION
    Everything.ini quirks these helpers exist for:
      - Inside a quoted value a backslash is stored doubled: C:\foo is written "C:\\foo".
      - The file uses CRLF. Git Bash's sed -i silently rewrites it to LF - edit it here instead.
      - Everything rewrites the whole file on exit, so an edit made while it runs is lost.
    Written for Everything 1.4. 1.5 (alpha) uses Everything64.exe and Everything-1.5a.ini.
#>

function Get-EverythingClient {
    <# Everything.exe processes in the current user's session. The "Everything" service runs in
       session 0 and holds only the volume handles; other users' instances are not ours. Exact
       name only: tools such as EverythingToolbar also start with "Everything". #>
    param([string[]]$Name = 'Everything')
    $session = (Get-Process -Id $PID).SessionId
    Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }
}

function Get-EverythingExe {
    $candidates = @(
        (Get-EverythingClient | Where-Object Path | Select-Object -First 1 -ExpandProperty Path),
        "$env:ProgramFiles\Everything\Everything.exe",
        "${env:ProgramFiles(x86)}\Everything\Everything.exe"
    )
    $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Get-EverythingSupportProblem {
    <# Returns why this setup is outside what the scripts were written for, or $null. #>
    param([string]$Exe)
    $v = (Get-Item -LiteralPath $Exe).VersionInfo
    if ($v.FileMajorPart -ne 1 -or $v.FileMinorPart -ne 4) {
        return "Everything $($v.FileVersion) - these scripts cover 1.4 only (1.5 uses Everything-1.5a.ini)"
    }
    $other = Get-EverythingClient -Name 'Everything64', 'Everything-1.5a' | Select-Object -First 1
    if ($other) { return "Everything 1.5 is running ($($other.ProcessName).exe)" }
    $null
}

function Get-EverythingIniPath {
    <# app_data=1 in the ini next to the exe moves the real settings to %APPDATA%\Everything.
       That is the installer's default, so the file beside the exe is usually a stub. #>
    param([string]$Exe)
    $dir = Split-Path $Exe
    $stub = Join-Path $dir 'Everything.ini'
    $useAppData = $true
    if (Test-Path -LiteralPath $stub) {
        $useAppData = [bool](Select-String -LiteralPath $stub -Pattern '^app_data=1' -Quiet)
    }
    $base = if ($useAppData) { Join-Path $env:APPDATA 'Everything' } else { $dir }
    Join-Path $base 'Everything.ini'
}

function Get-EverythingDbPath {
    <# db_location if set; otherwise %LOCALAPPDATA%\Everything for an %APPDATA% install, or
       beside the ini for a portable one. #>
    param([string]$IniPath)
    $ini = Read-EverythingIni $IniPath
    $loc = Get-IniValue $ini 'db_location'
    if ($loc) { return [Environment]::ExpandEnvironmentVariables($loc) }
    $iniDir = (Split-Path $IniPath).TrimEnd('\')
    if ($iniDir -eq (Join-Path $env:APPDATA 'Everything')) {
        return Join-Path $env:LOCALAPPDATA 'Everything\Everything.db'
    }
    Join-Path $iniDir 'Everything.db'
}

function Read-EverythingIni {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($bom) { $text = $text.Substring(1) }
    [pscustomobject]@{
        Path  = $Path
        Bom   = $bom
        Lines = [Collections.Generic.List[string]]($text -split "`r?`n")
    }
}

function Write-EverythingIni {
    <# Writes a temp file and swaps it in, so a crash mid-write cannot truncate the ini. #>
    param($Ini)
    $tmp = "$($Ini.Path).tmp"
    try {
        [IO.File]::WriteAllText($tmp, ($Ini.Lines -join "`r`n"), (New-Object Text.UTF8Encoding($Ini.Bom)))
        [IO.File]::Replace($tmp, $Ini.Path, [NullString]::Value)
    } catch {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        throw
    }
}

function Get-IniValue {
    param($Ini, [string]$Key)
    $line = $Ini.Lines | Where-Object { $_.StartsWith("$Key=") } | Select-Object -First 1
    if ($null -eq $line) { return $null }
    $line.Substring($Key.Length + 1)
}

function Set-IniValue {
    param($Ini, [string]$Key, [string]$Value)
    for ($i = 0; $i -lt $Ini.Lines.Count; $i++) {
        if ($Ini.Lines[$i].StartsWith("$Key=")) { $Ini.Lines[$i] = "$Key=$Value"; return }
    }
    # Missing key: append before the trailing empty line, if there is one
    $at = $Ini.Lines.Count
    if ($at -gt 0 -and $Ini.Lines[$at - 1] -eq '') { $at-- }
    $Ini.Lines.Insert($at, "$Key=$Value")
}

function ConvertFrom-IniList {
    <# '"C:\\a","b"' -> 'C:\a','b';  '1,0' -> '1','0'. Emits the items: wrap the call in @().
       Tolerates a mix of quoted and unquoted items rather than dropping the unquoted ones. #>
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return }
    if (-not $Value.Contains('"')) { return $Value -split ',' }
    foreach ($m in [regex]::Matches($Value, '"((?:[^"\\]|\\.)*)"|[^,]+')) {
        if ($m.Groups[1].Success) { $m.Groups[1].Value -replace '\\(.)', '$1' } else { $m.Value.Trim() }
    }
}

function ConvertTo-IniList {
    param([string[]]$Items, [switch]$Quoted)
    if (-not $Quoted) { return ($Items -join ',') }
    ($Items | ForEach-Object { '"' + ($_ -replace '\\', '\\' -replace '"', '\"') + '"' }) -join ','
}

function Get-EverythingVolumes {
    <# One object per configured NTFS/ReFS volume, from the index-aligned ntfs_volume_* and
       refs_volume_* lists. Root is a volume-relative sub-folder when the letter is a subst.
       Consistent is false when the lists disagree in length - don't edit by index then. #>
    param($Ini)
    foreach ($kind in 'ntfs', 'refs') {
        $list = @{}
        foreach ($k in 'guids', 'paths', 'roots', 'includes', 'monitors', 'include_onlys') {
            $list[$k] = @(ConvertFrom-IniList (Get-IniValue $Ini "${kind}_volume_$k"))
        }
        $n = $list.paths.Count
        $consistent = ($list.guids.Count -eq $n) -and ($list.includes.Count -eq $n) -and
            ($list.monitors.Count -eq $n -or $list.monitors.Count -eq 0) -and
            ($list.include_onlys.Count -eq $n -or $list.include_onlys.Count -eq 0)
        for ($i = 0; $i -lt $n; $i++) {
            [pscustomobject]@{
                Kind        = $kind
                Index       = $i
                Path        = $list.paths[$i]
                Guid        = if ($i -lt $list.guids.Count) { $list.guids[$i] } else { '' }
                Root        = if ($i -lt $list.roots.Count) { $list.roots[$i] } else { '' }
                IncludeOnly = if ($i -lt $list.include_onlys.Count) { $list.include_onlys[$i] } else { '' }
                Included    = ($i -lt $list.includes.Count) -and $list.includes[$i] -eq '1'
                Consistent  = $consistent
            }
        }
    }
}

function Get-RedundantVolumes {
    <# Included subst drives (S: = C:\Users\<user>\Shared) whose files are already indexed by a
       whole-volume entry for the same volume GUID with no include-only restriction. Everything
       indexes those files twice and runs a second journal monitor for them. Anything less
       certain - a missing GUID, an include-only list, misaligned lists - is left alone. #>
    param($Volumes)
    $included = @($Volumes | Where-Object { $_.Included -and $_.Consistent -and $_.Guid })
    foreach ($v in $included) {
        if (-not $v.Root) { continue }
        $whole = $included | Where-Object {
            $_.Kind -eq $v.Kind -and $_.Guid -eq $v.Guid -and -not $_.Root -and -not $_.IncludeOnly
        } | Select-Object -First 1
        if ($whole) { $v | Add-Member -NotePropertyName CoveredBy -NotePropertyValue $whole.Path -PassThru }
    }
}

function Get-PackageCacheFolders {
    <# Package caches hold hundreds of thousands of files nobody searches for by name.
       Resolved from the same variables the windows-dev-drive skill sets. #>
    $list = @(
        $env:NUGET_PACKAGES, "$env:USERPROFILE\.nuget\packages",
        $env:npm_config_cache, "$env:LOCALAPPDATA\npm-cache", "$env:APPDATA\npm-cache",
        $env:pnpm_config_store_dir, "$env:LOCALAPPDATA\pnpm\store",
        $env:PIP_CACHE_DIR, "$env:LOCALAPPDATA\pip\Cache",
        $env:UV_CACHE_DIR, "$env:LOCALAPPDATA\uv\cache",
        $env:VCPKG_DEFAULT_BINARY_CACHE, "$env:LOCALAPPDATA\vcpkg\archives",
        "$env:USERPROFILE\.m2\repository", "$env:USERPROFILE\.gradle\caches"
    )
    # pnpm without a configured store puts one at the root of each project drive. Fixed,
    # ready drives only: Test-Path on a disconnected network drive can hang for seconds.
    $list += [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        ForEach-Object { Join-Path $_.RootDirectory.FullName '.pnpm-store' }
    $found = @($list | Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        ForEach-Object { (Resolve-Path -LiteralPath $_).ProviderPath.TrimEnd('\') } |
        Sort-Object -Unique)
    # Drop caches nested inside another one (X:\packages\<user>\npm under X:\packages)
    foreach ($f in $found) {
        $others = @($found | Where-Object { $_ -ne $f })
        if (-not (Test-PathExcluded $f $others)) { $f }
    }
}

function Test-PathExcluded {
    <# True when the path, or any folder above it, matches one of the exclude entries.
       Entries with * or ? are wildcard filters (*\node_modules); the rest are plain paths,
       compared literally so a [ or ] in a real folder name is not read as a wildcard. #>
    param([string]$Path, [string[]]$Excludes)
    $p = $Path.TrimEnd('\')
    while ($p) {
        foreach ($e in $Excludes) {
            if (-not $e) { continue }
            $e = $e.TrimEnd('\')
            if ($e -match '[*?]') {
                if ($p -like ($e -replace '([\[\]`])', '`$1')) { return $true }
            } elseif ($p -eq $e) { return $true }
        }
        $parent = Split-Path $p
        if ($parent -eq $p) { break }
        $p = $parent
    }
    $false
}

# Folder-name filters: matched against any folder of that name, on every volume.
$script:DefaultExcludeFilters = @('*\node_modules', '*\.git', '*\bin', '*\obj', '*\$RECYCLE.BIN')
