<#
.SYNOPSIS
    Install a .template file as a real on-device reMarkable template — one you
    can pick per page and set as a notebook default, with unlimited pages.

.DESCRIPTION
    An imported PDF is a fixed stack of pages. A template is part of the device
    UI: it lives in /usr/share/remarkable/templates/ and is listed in
    templates.json.

    FORMAT NOTE. Older firmware used PNG images. Software 3.20+ (verified on
    build 20260612085811) uses a declarative vector DSL in *.template files —
    65 of them, zero PNGs. make_template.py --template emits that format.

    /usr/share is part of the system image, so a firmware update wipes it. This
    installs the way RCU does, which makes recovery one command:

      1. the real file goes in /home/root/.local/share/remarkable/templates/
         — under /home, which updates do not touch;
      2. a symlink points at it from /usr/share/remarkable/templates/;
      3. templates.json gets an entry, after a timestamped backup.

    The device has no python3, jq or perl — only busybox sh, awk and sed — so
    templates.json is edited *here* and copied back, rather than in place.

    THIS MODIFIES THE DEVICE and is unsupported by reMarkable. It does not touch
    your notebooks, and -Uninstall reverses it.

.PARAMETER Password
    SSH password from Settings > General > Help > About > Copyrights and
    licenses (at the bottom, with the IP). It changes on every firmware update.

.EXAMPLE
    .\Install-RemarkableTemplate.ps1 -Template .\Standup.template -Password xxx
    .\Install-RemarkableTemplate.ps1 -Name Standup -Uninstall -Password xxx
    .\Install-RemarkableTemplate.ps1 -Relink -Password xxx     # after an update
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $Template,

    # Defaults to the .template file's base name.
    [string] $Name,

    # Tab it appears under in the picker. The stock tabs are Creative, Lines,
    # Grids and Planners; a new name creates a new tab.
    [string] $Category = 'Planners',

    # Glyph shown beside the name. Must be a code the device font has —
    # borrowing a stock one is the safe move.  is the Checklist icon.
    [string] $IconCode = "",

    [string] $DeviceIp = '10.11.99.1',
    [string] $User = 'root',
    [string] $Password,

    [switch] $Uninstall,
    [switch] $Relink,
    [switch] $NoRestart
)

$ErrorActionPreference = 'Stop'

$STAGE = '/home/root/.local/share/remarkable/templates/custom'
$LIVE  = '/usr/share/remarkable/templates'
$JSON  = "$LIVE/templates.json"

if (-not $Name -and $Template) { $Name = [System.IO.Path]::GetFileNameWithoutExtension($Template) }

# ---- ssh plumbing -----------------------------------------------------------

$sshArgs = @(
    '-o', 'StrictHostKeyChecking=no'
    '-o', 'UserKnownHostsFile=NUL'          # the host key changes on every update
    '-o', 'ConnectTimeout=10'
)

# Same VPN problem as the web interface: a client owning 10.11.99.0/27 at a
# better metric swallows the connection. OpenSSH can bind the source address.
. (Join-Path $PSScriptRoot 'RemarkableWeb.ps1')
$bindIp = Get-RmBindAddress
if ($bindIp -and (Test-RmRouteHijacked)) {
    Write-Verbose "Route to $DeviceIp is not via the tablet's adapter; binding to $bindIp."
    $sshArgs += @('-o', "BindAddress=$bindIp")
}

if ($Password) {
    $askScript = Join-Path ([System.IO.Path]::GetTempPath()) "rmask-$([guid]::NewGuid().ToString('N')).cmd"
    Set-Content -Path $askScript -Value "@echo off`r`necho $Password" -Encoding ASCII `
                -WhatIf:$false -Confirm:$false
    $env:SSH_ASKPASS = $askScript
    $env:SSH_ASKPASS_REQUIRE = 'force'
    $env:DISPLAY = 'none'
}

function Invoke-Rm {
    param([Parameter(Mandatory)][string] $Cmd)
    $out = & ssh @sshArgs "$User@$DeviceIp" $Cmd 2>&1 | Where-Object { $_ -notmatch '^Warning: Permanently added' }
    if ($LASTEXITCODE -ne 0) { throw "ssh failed ($LASTEXITCODE): $out" }
    return $out
}
function Push-Rm { param([string]$Local,[string]$Remote)
    $o = & scp @sshArgs -- $Local "$User@${DeviceIp}:$Remote" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "scp up failed ($LASTEXITCODE): $o" } }
function Pull-Rm { param([string]$Remote,[string]$Local)
    $o = & scp @sshArgs -- "$User@${DeviceIp}:$Remote" $Local 2>&1
    if ($LASTEXITCODE -ne 0) { throw "scp down failed ($LASTEXITCODE): $o" } }

try {
    $fw = (Invoke-Rm 'cat /etc/version') -join ''
    Write-Verbose "device firmware $fw"

    if ($Relink) {
        if (-not $PSCmdlet.ShouldProcess($DeviceIp, 'relink staged templates after a firmware update')) { return }
        Invoke-Rm "mkdir -p '$STAGE'; n=0; for f in '$STAGE'/*.template; do [ -e `"`$f`" ] || continue; ln -sf `"`$f`" '$LIVE'/`"`$(basename `"`$f`")`"; n=`$((n+1)); done; echo `"relinked `$n file(s)`""
        Write-Warning 'Symlinks restored. templates.json entries still need re-adding — re-run the install for each template.'
    }
    else {
        if (-not $Name) { throw 'Give -Template (or -Name with -Uninstall).' }
        $action = if ($Uninstall) { "remove template '$Name'" } else { "install template '$Name' (modifies the device)" }
        if (-not $PSCmdlet.ShouldProcess($DeviceIp, $action)) { return }

        # --- edit templates.json here; the device has no JSON tooling ---------
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "rmtj-$([guid]::NewGuid().ToString('N')).json"
        Pull-Rm -Remote $JSON -Local $tmp
        $doc = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json

        $before = $doc.templates.Count
        $doc.templates = @($doc.templates | Where-Object { $_.name -ne $Name })

        if (-not $Uninstall) {
            Invoke-Rm "mkdir -p '$STAGE'"
            Push-Rm -Local (Resolve-Path $Template) -Remote "$STAGE/$Name.template"
            Invoke-Rm "ln -sf '$STAGE/$Name.template' '$LIVE/$Name.template'"

            $doc.templates += [pscustomobject]@{
                name       = $Name
                filename   = $Name
                iconCode   = $IconCode
                categories = @($Category)
            }
        }
        else {
            Invoke-Rm "rm -f '$LIVE/$Name.template'"
        }

        # Back up once (the pristine original) and every time (the last good one).
        Invoke-Rm "[ -f '$STAGE/templates.json.orig' ] || cp '$JSON' '$STAGE/templates.json.orig'; cp '$JSON' '$STAGE/templates.json.bak'"

        $json = $doc | ConvertTo-Json -Depth 8
        # ConvertTo-Json escapes the backslash in the  icon code; undo that.
        $json = $json -replace '\\\\u', '\u'
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Push-Rm -Local $tmp -Remote $JSON
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue -WhatIf:$false

        "templates.json: $before -> $($doc.templates.Count) entries"
    }

    if (-not $NoRestart -and $PSCmdlet.ShouldProcess($DeviceIp, 'restart the UI (xochitl)')) {
        & ssh @sshArgs "$User@$DeviceIp" 'systemctl restart xochitl' 2>&1 | Out-Null
        'Restarted the UI — the template appears in the picker in a few seconds.'
    }
}
finally {
    if ($askScript -and (Test-Path $askScript)) {
        Remove-Item $askScript -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
    }
    Remove-Item Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE, Env:DISPLAY `
                -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
}
