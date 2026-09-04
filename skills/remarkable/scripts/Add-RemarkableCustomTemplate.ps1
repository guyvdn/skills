<#
.SYNOPSIS
    Install a .template as a **custom template library entry** — reMarkable's own
    supported mechanism, the one templates from methods.remarkable.com use.

.DESCRIPTION
    This is the route to prefer. Install-RemarkableTemplate.ps1 uses the legacy
    /usr/share + templates.json method that every older guide describes; that
    works, but a firmware update replaces /usr/share and wipes it.

    A custom template is a **library entry**, like a notebook — xochitl's
    customtemplate.cpp lives under src/entry/ — so it sits in /home, survives
    firmware updates, and syncs to the cloud. Three files plus a thumbnail, all
    in /home/root/.local/share/remarkable/xochitl/:

        <uuid>.metadata            {"type": "TemplateType", "visibleName": ...}
        <uuid>.content             {}
        <uuid>.template            the DSL, with base64 iconData
        <uuid>.thumbnails/1-0-1.svg   the same 150x200 icon, unencoded

    No templates.json anywhere. Schema read off a real Methods template rather
    than guessed.

.EXAMPLE
    .\Add-RemarkableCustomTemplate.ps1 -Template .\Standup.template -Password xxx
    .\Add-RemarkableCustomTemplate.ps1 -Name Standup -Uninstall -Password xxx
    .\Add-RemarkableCustomTemplate.ps1 -List -Password xxx
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Template,

    # Defaults to the .template file's own "name", else its base name.
    [string] $Name,

    # Optional 150x200 SVG for the picker. Defaults to the .icon.svg that
    # make_template.py writes beside the template.
    [string] $Icon,

    [string] $DeviceIp = '10.11.99.1',
    [string] $User = 'root',
    [string] $Password,

    [switch] $Uninstall,
    [switch] $List,
    [switch] $NoRestart
)

$ErrorActionPreference = 'Stop'
$X = '/home/root/.local/share/remarkable/xochitl'

$sshArgs = @(
    '-o', 'StrictHostKeyChecking=no'
    '-o', 'UserKnownHostsFile=NUL'
    '-o', 'ConnectTimeout=10'
)
. (Join-Path $PSScriptRoot 'RemarkableWeb.ps1')
$bindIp = Get-RmBindAddress
if ($bindIp -and (Test-RmRouteHijacked)) { $sshArgs += @('-o', "BindAddress=$bindIp") }

if ($Password) {
    $askScript = Join-Path ([System.IO.Path]::GetTempPath()) "rmask-$([guid]::NewGuid().ToString('N')).cmd"
    Set-Content -Path $askScript -Value "@echo off`r`necho $Password" -Encoding ASCII -WhatIf:$false -Confirm:$false
    $env:SSH_ASKPASS = $askScript; $env:SSH_ASKPASS_REQUIRE = 'force'; $env:DISPLAY = 'none'
}

function Invoke-Rm { param([string]$Cmd)
    $o = & ssh @sshArgs "$User@$DeviceIp" $Cmd 2>&1 | Where-Object { $_ -notmatch '^Warning: Permanently added' }
    if ($LASTEXITCODE -ne 0) { throw "ssh failed ($LASTEXITCODE): $o" }
    return $o }
function Push-Rm { param([string]$Local,[string]$Remote)
    $o = & scp @sshArgs -- $Local "$User@${DeviceIp}:$Remote" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "scp failed ($LASTEXITCODE): $o" } }

function Get-RmTemplateEntries {
    # A custom template is any library entry whose .metadata says TemplateType.
    # Single-quoted here-string: everything below is literal, so the remote sh
    # sees exactly this and PowerShell escaping cannot mangle it. Only __X__ is
    # substituted afterwards.
    $script = @'
for f in __X__/*.metadata; do
  [ -e "$f" ] || continue
  grep -q '"type": "TemplateType"' "$f" || continue
  id=$(basename "$f" .metadata)
  n=$(grep -o '"visibleName": "[^"]*"' "$f" | cut -d'"' -f4)
  echo "$id|$n"
done
'@ -replace '__X__', $X

    foreach ($line in @(Invoke-Rm $script)) {
        if ($line -match '^([0-9a-f-]{36})\|(.*)$') {
            [pscustomobject]@{ Id = $Matches[1]; Name = $Matches[2] }
        }
    }
}

try {
    if ($List) { Get-RmTemplateEntries; return }

    if ($Uninstall) {
        if (-not $Name) { throw 'Give -Name to uninstall.' }
        $hit = @(Get-RmTemplateEntries | Where-Object Name -eq $Name)
        if (-not $hit) { throw "No custom template entry named '$Name'." }
        foreach ($e in $hit) {
            if ($PSCmdlet.ShouldProcess("$($e.Name) ($($e.Id))", 'remove custom template entry')) {
                Invoke-Rm "rm -rf '$X/$($e.Id).metadata' '$X/$($e.Id).content' '$X/$($e.Id).template' '$X/$($e.Id).thumbnails'"
                "removed $($e.Name) [$($e.Id)]"
            }
        }
    }
    else {
        if (-not $Template) { throw 'Give -Template.' }
        $tpl = Get-Item $Template
        $doc = Get-Content $tpl -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $Name) { $Name = if ($doc.name) { $doc.name } else { $tpl.BaseName } }
        if (-not $Icon) {
            $guess = Join-Path $tpl.DirectoryName ($tpl.BaseName + '.icon.svg')
            if (Test-Path $guess) { $Icon = $guess }
        }

        if (-not $PSCmdlet.ShouldProcess("$DeviceIp", "install custom template '$Name'")) { return }

        # Replace an entry of the same name rather than stacking duplicates.
        foreach ($e in @(Get-RmTemplateEntries | Where-Object Name -eq $Name)) {
            Invoke-Rm "rm -rf '$X/$($e.Id).metadata' '$X/$($e.Id).content' '$X/$($e.Id).template' '$X/$($e.Id).thumbnails'"
            Write-Verbose "replaced existing entry $($e.Id)"
        }

        $uuid = [guid]::NewGuid().ToString()
        $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString()
        $meta = [ordered]@{
            createdTime  = $ms
            lastModified = $ms
            new          = $false
            parent       = ''
            pinned       = $false
            source       = 'com.remarkable.methods'
            type         = 'TemplateType'
            visibleName  = $Name
        } | ConvertTo-Json

        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "rmct-$($uuid.Substring(0,8))"
        New-Item -ItemType Directory -Path $tmp -Force -WhatIf:$false | Out-Null
        try {
            [System.IO.File]::WriteAllText("$tmp\$uuid.metadata", $meta, (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText("$tmp\$uuid.content", '{}', (New-Object System.Text.UTF8Encoding($false)))

            Push-Rm -Local "$tmp\$uuid.metadata" -Remote "$X/$uuid.metadata"
            Push-Rm -Local "$tmp\$uuid.content"  -Remote "$X/$uuid.content"
            Push-Rm -Local $tpl.FullName         -Remote "$X/$uuid.template"

            if ($Icon -and (Test-Path $Icon)) {
                Invoke-Rm "mkdir -p '$X/$uuid.thumbnails'"
                Push-Rm -Local (Resolve-Path $Icon) -Remote "$X/$uuid.thumbnails/1-0-1.svg"
            }
        }
        finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }

        [pscustomobject]@{ Name = $Name; Id = $uuid; Icon = [bool]$Icon }
    }

    if (-not $NoRestart -and $PSCmdlet.ShouldProcess($DeviceIp, 'restart the UI (xochitl)')) {
        & ssh @sshArgs "$User@$DeviceIp" 'systemctl restart xochitl' 2>&1 | Out-Null
        'Restarted the UI.'
    }
}
finally {
    if ($askScript -and (Test-Path $askScript)) {
        Remove-Item $askScript -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
    }
    Remove-Item Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE, Env:DISPLAY -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
}
