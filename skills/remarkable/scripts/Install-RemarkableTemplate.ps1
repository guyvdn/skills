<#
.SYNOPSIS
    Install a PNG as a real on-device reMarkable template — one you can pick per
    page and set as a notebook's default, with unlimited pages.

.DESCRIPTION
    Unlike an imported PDF (which is a fixed stack of pages), a template is part
    of the device UI. It lives in /usr/share/remarkable/templates/ and is listed
    in templates.json.

    That directory is part of the system image, so **a firmware update wipes it**.
    This installs the way RCU does, which survives that with one command:

      1. the real files go in /home/root/.local/share/remarkable/templates/
         — under /home, which updates do not touch;
      2. symlinks point at them from /usr/share/remarkable/templates/;
      3. templates.json gets an entry, after a timestamped backup.

    After a firmware update the symlinks and the json entry are gone but your
    files are not: re-run this script and it relinks in seconds.

    THIS MODIFIES THE DEVICE. It is unsupported by reMarkable. It does not void
    a warranty or touch your notebooks, and -Uninstall reverses it, but treat it
    as a deliberate act rather than a convenience.

.PARAMETER Password
    The device's SSH password, from Settings > General > Help > About >
    Copyrights and licenses (scroll to the bottom — it is shown with the IP).
    It changes on every firmware update.

    Omit it and ssh will prompt, which needs an interactive terminal.

.EXAMPLE
    .\Install-RemarkableTemplate.ps1 -Png .\Standup.png -Name 'Standup'
    .\Install-RemarkableTemplate.ps1 -Png .\Standup.png -Name 'Standup' -Svg .\Standup.svg
    .\Install-RemarkableTemplate.ps1 -Name 'Standup' -Uninstall
    .\Install-RemarkableTemplate.ps1 -Relink          # after a firmware update
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $Png,
    [string] $Svg,

    # Name shown in the template picker.
    [string] $Name,

    # Category tab it appears under.
    [string] $Category = 'Custom',

    [string] $DeviceIp = '10.11.99.1',
    [string] $User = 'root',
    [string] $Password,

    [switch] $Uninstall,

    # Re-create symlinks and json entries for everything already staged in
    # /home/root — what you run after a firmware update.
    [switch] $Relink,

    # Skip restarting xochitl (the UI); templates appear after the next restart.
    [switch] $NoRestart
)

$ErrorActionPreference = 'Stop'

$STAGE = '/home/root/.local/share/remarkable/templates'
$LIVE  = '/usr/share/remarkable/templates'
$JSON  = "$LIVE/templates.json"

# ---- ssh plumbing -----------------------------------------------------------

$sshArgs = @(
    '-o', 'StrictHostKeyChecking=no'
    '-o', 'UserKnownHostsFile=NUL'          # the host key changes on every update
    '-o', 'ConnectTimeout=10'
)

# Same VPN problem as the web interface: a client that owns 10.11.99.0/27 at a
# better metric swallows the connection. OpenSSH can bind the source address,
# which picks the tablet's interface regardless of the route table.
. (Join-Path $PSScriptRoot 'RemarkableWeb.ps1')
$bind = Get-RmBindAddress
if ($bind -and (Test-RmRouteHijacked)) {
    Write-Verbose "Route to $DeviceIp is not via the tablet's adapter; binding to $bind."
    $sshArgs += @('-o', "BindAddress=$bind")
}

if ($Password) {
    # OpenSSH has no password flag. SSH_ASKPASS with SSH_ASKPASS_REQUIRE=force
    # feeds it without echoing the password into the command line.
    $askScript = Join-Path ([System.IO.Path]::GetTempPath()) "rmask-$([guid]::NewGuid().ToString('N')).cmd"
    Set-Content -Path $askScript -Value "@echo off`r`necho $Password" -Encoding ASCII
    $env:SSH_ASKPASS = $askScript
    $env:SSH_ASKPASS_REQUIRE = 'force'
    $env:DISPLAY = 'none'
}

function Invoke-Rm {
    param([Parameter(Mandatory)][string] $Cmd)
    $out = & ssh @sshArgs "$User@$DeviceIp" $Cmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh failed ($LASTEXITCODE): $out" }
    return $out
}

function Copy-ToRm {
    param([string] $Local, [string] $Remote)
    $out = & scp @sshArgs -- $Local "$User@${DeviceIp}:$Remote" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "scp failed ($LASTEXITCODE): $out" }
}

try {
    # ---- connectivity + a look at what we are about to change ---------------
    $ver = Invoke-Rm 'cat /etc/version 2>/dev/null; echo "---"; ls /usr/share/remarkable/templates/*.png 2>/dev/null | wc -l'
    Write-Verbose "device responded: $ver"

    if ($Relink) {
        $Uninstall = $false
        if (-not $PSCmdlet.ShouldProcess($DeviceIp, 'relink staged templates after a firmware update')) { return }
        $script = @"
set -e
mkdir -p '$STAGE'
n=0
for f in '$STAGE'/*.png '$STAGE'/*.svg; do
  [ -e "`$f" ] || continue
  ln -sf "`$f" '$LIVE'/"`$(basename "`$f")"
  n=`$((n+1))
done
echo "relinked `$n file(s)"
"@
        Invoke-Rm $script
        Write-Warning "Symlinks restored. templates.json entries still need re-adding — re-run this script with -Png/-Name for each template."
    }
    elseif ($Uninstall) {
        if (-not $Name) { throw 'Give -Name to uninstall.' }
        if (-not $PSCmdlet.ShouldProcess("$Name on $DeviceIp", 'remove template')) { return }
        $script = @"
set -e
python3 - <<'PY'
import json
p = '$JSON'
d = json.load(open(p))
before = len(d['templates'])
d['templates'] = [t for t in d['templates'] if t.get('name') != '$Name']
json.dump(d, open(p, 'w'), indent=4, ensure_ascii=False)
print(f"removed {before - len(d['templates'])} entry(ies) from templates.json")
PY
rm -f '$LIVE/$Name.png' '$LIVE/$Name.svg'
echo "left the staged copies in $STAGE"
"@
        Invoke-Rm $script
    }
    else {
        if (-not $Png -or -not $Name) { throw 'Give -Png and -Name to install.' }
        if (-not (Test-Path $Png)) { throw "No such file: $Png" }
        if (-not $PSCmdlet.ShouldProcess("$DeviceIp", "install template '$Name' (modifies the device)")) { return }

        Invoke-Rm "mkdir -p '$STAGE'"
        Copy-ToRm -Local (Resolve-Path $Png) -Remote "$STAGE/$Name.png"
        if ($Svg) { Copy-ToRm -Local (Resolve-Path $Svg) -Remote "$STAGE/$Name.svg" }

        # Back up templates.json once, then add the entry idempotently.
        $script = @"
set -e
[ -f '$STAGE/templates.json.orig' ] || cp '$JSON' '$STAGE/templates.json.orig'
cp '$JSON' '$JSON.bak'

ln -sf '$STAGE/$Name.png' '$LIVE/$Name.png'
[ -f '$STAGE/$Name.svg' ] && ln -sf '$STAGE/$Name.svg' '$LIVE/$Name.svg'

python3 - <<'PY'
import json
p = '$JSON'
d = json.load(open(p))
d.setdefault('templates', [])
d['templates'] = [t for t in d['templates'] if t.get('name') != '$Name']
d['templates'].append({
    'name': '$Name',
    'filename': '$Name',
    'iconCode': '',
    'categories': ['$Category'],
})
json.dump(d, open(p, 'w'), indent=4, ensure_ascii=False)
print(f"templates.json now lists {len(d['templates'])} templates")
PY
"@
        Invoke-Rm $script
    }

    if (-not $NoRestart) {
        if ($PSCmdlet.ShouldProcess($DeviceIp, 'restart xochitl (the UI blinks; nothing is lost)')) {
            # The restart kills our own shell, so ignore its exit code.
            & ssh @sshArgs "$User@$DeviceIp" 'systemctl restart xochitl' 2>&1 | Out-Null
            Write-Host 'Restarted the UI — the template picker will list it in a few seconds.'
        }
    }
}
finally {
    if ($askScript -and (Test-Path $askScript)) { Remove-Item $askScript -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE, Env:DISPLAY -ErrorAction SilentlyContinue
}
