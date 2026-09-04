<#
.SYNOPSIS
    Download one reMarkable notebook as a PDF (or as a raw .rmdoc archive).

.DESCRIPTION
    Over USB the tablet renders the PDF itself, so every pen, colour,
    highlighter, template background and underlying PDF annotation comes out
    exactly as it looks on the device. That is the whole reason USB is the
    preferred transport -- no third-party renderer matches it.

    Over the cloud, rmapi's 'geta' rasterises the strokes instead. Legible,
    but template backgrounds and some pen styles differ.

    Big notebooks take a while to render on-device: the default timeout is
    generous on purpose.

.EXAMPLE
    .\Export-RemarkableDoc.ps1 -Name 'Architecture notes' -OutFile .\notes.pdf
    .\Export-RemarkableDoc.ps1 -Id 3f2b... -OutFile .\notes.pdf
    .\Export-RemarkableDoc.ps1 -Name 'Sprint 12' -Format rmdoc -OutFile .\raw.rmdoc
#>
[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [string] $Name,

    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [string] $Id,

    [Parameter(Mandatory)]
    [string] $OutFile,

    [ValidateSet('pdf', 'rmdoc')]
    [string] $Format = 'pdf',

    [ValidateSet('auto', 'usb', 'cloud')]
    [string] $Transport = 'auto',

    [string] $BaseUrl = 'http://10.11.99.1',

    # On-device PDF rendering of a long notebook is not fast.
    [int] $TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
$script:NoProxySupported = $PSVersionTable.PSVersion.Major -ge 6
$listScript = Join-Path $PSScriptRoot 'Get-RemarkableDocs.ps1'

function Test-UsbTransport {
    try {
        $splat = @{ Uri = "$BaseUrl/documents/"; TimeoutSec = 10; ErrorAction = 'Stop' }
        if ($script:NoProxySupported) { $splat['NoProxy'] = $true }
        $null = Invoke-RestMethod @splat
        return $true
    } catch { return $false }
}

function Get-RmapiExe {
    $cmd = Get-Command rmapi -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $goBin = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'go\bin\rmapi.exe'
    if (Test-Path $goBin) { return $goBin }
    throw 'rmapi not found. Install with: go install github.com/ddvk/rmapi@latest'
}

$useUsb = switch ($Transport) {
    'usb'   { $true }
    'cloud' { $false }
    default { Test-UsbTransport }
}

# ---- resolve the name to a document -----------------------------------------

$doc = $null
if ($PSCmdlet.ParameterSetName -eq 'ByName') {
    $transportArg = if ($useUsb) { 'usb' } else { 'cloud' }
    $all = & $listScript -Transport $transportArg -DocumentsOnly -Json | ConvertFrom-Json

    $hits = @($all | Where-Object { $_.Path -eq $Name -or $_.Name -eq $Name })
    if ($hits.Count -eq 0) {
        $hits = @($all | Where-Object { $_.Path -like "*$Name*" })
    }

    if ($hits.Count -eq 0) {
        throw "No document matching '$Name'. Run Get-RemarkableDocs.ps1 to see what is there."
    }
    if ($hits.Count -gt 1) {
        $list = ($hits | ForEach-Object { "  $($_.Path)" }) -join "`n"
        throw "'$Name' matches $($hits.Count) documents. Be more specific, or pass -Id.`n$list"
    }

    $doc = $hits[0]
    $Id  = $doc.Id
    Write-Verbose "Resolved '$Name' -> $($doc.Path) ($Id)"
}

$OutFile = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $OutFile))
$outDir  = Split-Path $OutFile -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# ---- fetch -------------------------------------------------------------------

if ($useUsb) {
    $uri = "$BaseUrl/download/$Id/$Format"
    Write-Verbose "GET $uri"
    $splat = @{ Uri = $uri; OutFile = $OutFile; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($script:NoProxySupported) { $splat['NoProxy'] = $true }
    Invoke-WebRequest @splat
}
else {
    if ($Format -eq 'rmdoc') { throw 'rmdoc export is USB-only. Use -Format pdf over the cloud.' }
    if (-not $doc) { throw 'The cloud transport needs -Name (rmapi addresses documents by path, not id).' }

    $exe  = Get-RmapiExe
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("rm-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        Push-Location $temp
        # geta writes into the cwd under a name it chooses, so render into an
        # empty directory and pick up whatever PDF appears.
        $out = & $exe geta "/$($doc.Path)" 2>&1
        Pop-Location
        if ($LASTEXITCODE -ne 0) { throw "rmapi geta failed: $out" }

        $pdf = Get-ChildItem $temp -Filter *.pdf | Select-Object -First 1
        if (-not $pdf) { throw "rmapi geta produced no PDF. Output: $out" }
        Move-Item $pdf.FullName $OutFile -Force
    }
    finally {
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path $OutFile)) { throw "Export produced nothing at $OutFile." }

$item = Get-Item $OutFile
if ($item.Length -lt 1024) {
    throw "Export at $OutFile is only $($item.Length) bytes -- almost certainly an error page, not a document."
}

[pscustomobject]@{
    Path      = $doc.Path
    Id        = $Id
    Format    = $Format
    File      = $item.FullName
    SizeKB    = [math]::Round($item.Length / 1KB, 1)
    Transport = if ($useUsb) { 'usb' } else { 'cloud' }
}
