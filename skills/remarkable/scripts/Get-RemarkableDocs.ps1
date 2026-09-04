<#
.SYNOPSIS
    List the notebooks and folders on a reMarkable tablet.

.DESCRIPTION
    Walks the document tree over one of two transports:

      usb    the tablet's own USB web interface at http://10.11.99.1
             (Settings > Storage > USB web interface). No auth, no
             dependencies, and the tablet renders its own PDFs later.

      cloud  the reMarkable cloud via ddvk/rmapi. Works without the
             tablet present; needs a one-time setup and a Connect
             subscription.

    -Transport auto (the default) probes USB first and falls back to cloud.

.EXAMPLE
    .\Get-RemarkableDocs.ps1
    .\Get-RemarkableDocs.ps1 -Match 'architecture' -Json
    .\Get-RemarkableDocs.ps1 -Transport cloud
#>
[CmdletBinding()]
param(
    [ValidateSet('auto', 'usb', 'cloud')]
    [string] $Transport = 'auto',

    # Regex filtered against the document's full path.
    [string] $Match,

    # Emit objects as JSON instead of a table.
    [switch] $Json,

    # Only notebooks/PDFs, skip folders.
    [switch] $DocumentsOnly,

    [string] $BaseUrl = 'http://10.11.99.1',

    [int] $TimeoutSec = 20
)

$ErrorActionPreference = 'Stop'

# PowerShell 7 can bypass the system proxy per request; 5.1 cannot, and a
# corporate proxy will happily swallow a request to 10.11.99.1.
$script:NoProxySupported = $PSVersionTable.PSVersion.Major -ge 6

function Invoke-RmWeb {
    param([string] $Uri)
    $splat = @{ Uri = $Uri; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($script:NoProxySupported) { $splat['NoProxy'] = $true }
    Invoke-RestMethod @splat
}

function Test-UsbTransport {
    try { $null = Invoke-RmWeb "$BaseUrl/documents/"; return $true }
    catch { return $false }
}

function Get-RmapiExe {
    $cmd = Get-Command rmapi -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $goBin = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'go\bin\rmapi.exe'
    if (Test-Path $goBin) { return $goBin }
    return $null
}

function Get-UsbTree {
    param([string] $Guid = '', [string] $Prefix = '')

    $entries = Invoke-RmWeb "$BaseUrl/documents/$Guid"
    foreach ($e in @($entries)) {
        # 'VissibleName' is the tablet's own spelling. Not a typo here.
        $name = $e.VissibleName
        if (-not $name) { $name = $e.Name }
        $path = if ($Prefix) { "$Prefix/$name" } else { $name }

        $isFolder = $e.Type -eq 'CollectionType'
        $kind = if ($isFolder) { 'folder' }
                elseif ($e.fileType) { $e.fileType }
                else { 'notebook' }

        [pscustomobject]@{
            Path      = $path
            Name      = $name
            Id        = $e.ID
            Kind      = $kind
            Pages     = $e.pageCount
            Modified  = $e.ModifiedClient
            Transport = 'usb'
        }

        if ($isFolder) { Get-UsbTree -Guid $e.ID -Prefix $path }
    }
}

function Get-CloudTree {
    $exe = Get-RmapiExe
    if (-not $exe) {
        throw "rmapi not found. Install with: go install github.com/ddvk/rmapi@latest (then add %USERPROFILE%\go\bin to PATH). See references/transports.md."
    }

    # find <dir> <regex> --json walks the whole tree in one call.
    $raw = & $exe find --json / '.' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "rmapi find failed: $raw`nOn a first run, authenticate with a one-time code from https://my.remarkable.com/device/browser/connect"
    }

    $items = $raw | ConvertFrom-Json
    foreach ($i in @($items)) {
        $path = @($i.Path, $i.path, $i.Name) | Where-Object { $_ } | Select-Object -First 1
        $id   = @($i.ID, $i.Id, $i.id)       | Where-Object { $_ } | Select-Object -First 1
        [pscustomobject]@{
            Path      = ($path -replace '^/', '')
            Name      = Split-Path $path -Leaf
            Id        = $id
            Kind      = if ($i.Type -eq 'CollectionType' -or $i.IsFolder) { 'folder' } else { 'notebook' }
            Pages     = $null
            Modified  = $i.ModifiedClient
            Transport = 'cloud'
        }
    }
}

# ---- pick a transport -------------------------------------------------------

if ($Transport -eq 'usb' -and -not (Test-UsbTransport)) {
    throw @"
Cannot reach the USB web interface at $BaseUrl.

Check, in order:
  1. Settings > Storage > USB web interface is ON (it resets on some updates).
  2. An adapter named like 'USB Remote NDIS Network Device' is Up:
       Get-NetAdapter | Where-Object InterfaceDescription -match 'NDIS'
  3. Nothing else owns the 10.11.99.0/27 route -- a VPN commonly does:
       Find-NetRoute -RemoteIPAddress 10.11.99.1 | Select-Object -First 1 InterfaceAlias
     If that names your VPN rather than the tablet's adapter, see
     references/troubleshooting.md ("A VPN steals the tablet's subnet").
"@
}

$useUsb = switch ($Transport) {
    'usb'   { $true }
    'cloud' { $false }
    default {
        if (Test-UsbTransport) { $true }
        else { Write-Verbose 'USB web interface not reachable; falling back to cloud.'; $false }
    }
}

$rows = if ($useUsb) { Get-UsbTree } else { Get-CloudTree }

if ($DocumentsOnly) { $rows = $rows | Where-Object Kind -ne 'folder' }
if ($Match)         { $rows = $rows | Where-Object { $_.Path -match $Match } }

$rows = $rows | Sort-Object Path

if ($Json) { $rows | ConvertTo-Json -Depth 5 }
else       { $rows | Format-Table Path, Kind, Pages, Modified, Id -AutoSize }
