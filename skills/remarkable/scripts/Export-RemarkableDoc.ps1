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

    # Export every document under this folder path, into -OutDir.
    [Parameter(Mandatory, ParameterSetName = 'ByFolder')]
    [string] $Folder,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [string] $OutFile,

    [Parameter(Mandatory, ParameterSetName = 'ByFolder')]
    [string] $OutDir,

    # Batch mode: skip documents already exported (resume after an interruption).
    [Parameter(ParameterSetName = 'ByFolder')]
    [switch] $SkipExisting,

    [ValidateSet('pdf', 'rmdoc')]
    [string] $Format = 'pdf',

    [ValidateSet('auto', 'usb', 'cloud')]
    [string] $Transport = 'auto',

    [string] $BaseUrl = 'http://10.11.99.1',

    # On-device PDF rendering of a long notebook is not fast.
    [int] $TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RemarkableWeb.ps1')
$listScript = Join-Path $PSScriptRoot 'Get-RemarkableDocs.ps1'

function Test-UsbTransport {
    try { $null = Invoke-RmJson -Uri "$BaseUrl/documents/" -TimeoutSec 10; return $true }
    catch { return $false }
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

# Notebook titles are free text and routinely contain '/' ("DP3/GHC Sync",
# "UI/UX"), ':' and '?'. None of those survive as a Windows filename.
function ConvertTo-SafeFileName {
    param([string] $Text)
    $safe = $Text
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$c, '-')
    }
    $safe = ($safe -replace '\s+', ' ').Trim(' ', '.')
    if (-not $safe) { $safe = 'untitled' }
    return $safe
}

function Export-One {
    param(
        [Parameter(Mandatory)] $Doc,     # object with .Path and .Id, or $null when -Id was given
        [Parameter(Mandatory)] [string] $DocId,
        [Parameter(Mandatory)] [string] $Destination
    )

    # Join-Path concatenates blindly, so an already-absolute destination would
    # come out as '<cwd>\D:\...'. Resolve against the cwd only when relative.
    $Destination = if ([System.IO.Path]::IsPathRooted($Destination)) {
        [System.IO.Path]::GetFullPath($Destination)
    } else {
        [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).Path, $Destination))
    }
    $parent = Split-Path $Destination -Parent
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    if ($useUsb) {
        $uri = "$BaseUrl/download/$DocId/$Format"
        Write-Verbose "GET $uri"
        Save-RmFile -Uri $uri -OutFile $Destination -TimeoutSec $TimeoutSec
    }
    else {
        if ($Format -eq 'rmdoc') { throw 'rmdoc export is USB-only. Use -Format pdf over the cloud.' }
        if (-not $Doc) { throw 'The cloud transport needs -Name or -Folder (rmapi addresses documents by path, not id).' }

        $exe  = Get-RmapiExe
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("rm-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        try {
            Push-Location $temp
            # geta writes into the cwd under a name it chooses, so render into
            # an empty directory and pick up whatever PDF appears.
            $out = & $exe geta "/$($Doc.Path)" 2>&1
            Pop-Location
            if ($LASTEXITCODE -ne 0) { throw "rmapi geta failed: $out" }

            $pdf = Get-ChildItem $temp -Filter *.pdf | Select-Object -First 1
            if (-not $pdf) { throw "rmapi geta produced no PDF. Output: $out" }
            Move-Item $pdf.FullName $Destination -Force
        }
        finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if (-not (Test-Path $Destination)) { throw "Export produced nothing at $Destination." }
    $item = Get-Item $Destination
    if ($item.Length -lt 1024) {
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        throw "Export was only $($item.Length) bytes -- an error page, not a document."
    }

    [pscustomobject]@{
        Path      = if ($Doc) { $Doc.Path } else { $null }
        Id        = $DocId
        Format    = $Format
        File      = $item.FullName
        SizeKB    = [math]::Round($item.Length / 1KB, 1)
        Transport = if ($useUsb) { 'usb' } else { 'cloud' }
    }
}

$transportArg = if ($useUsb) { 'usb' } else { 'cloud' }

switch ($PSCmdlet.ParameterSetName) {

    'ById' { Export-One -Doc $null -DocId $Id -Destination $OutFile }

    'ByName' {
        $all = & $listScript -Transport $transportArg -DocumentsOnly -Json | ConvertFrom-Json

        $hits = @($all | Where-Object { $_.Path -eq $Name -or $_.Name -eq $Name })
        if ($hits.Count -eq 0) { $hits = @($all | Where-Object { $_.Path -like "*$Name*" }) }

        if ($hits.Count -eq 0) {
            throw "No document matching '$Name'. Run Get-RemarkableDocs.ps1 to see what is there."
        }
        if ($hits.Count -gt 1) {
            $list = ($hits | ForEach-Object { "  $($_.Path)" }) -join "`n"
            throw "'$Name' matches $($hits.Count) documents. Be more specific, or pass -Id.`n$list"
        }

        Write-Verbose "Resolved '$Name' -> $($hits[0].Path)"
        Export-One -Doc $hits[0] -DocId $hits[0].Id -Destination $OutFile
    }

    'ByFolder' {
        $all  = & $listScript -Transport $transportArg -DocumentsOnly -Json | ConvertFrom-Json
        $trim = $Folder.Trim('/')
        $docs = @($all | Where-Object { $_.Path -like "$trim/*" } | Sort-Object Path)

        if ($docs.Count -eq 0) { throw "No documents under folder '$Folder'." }

        if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

        $n = 0
        foreach ($d in $docs) {
            $n++
            # Flatten the path below the folder so nested notebooks cannot collide.
            $rel  = $d.Path.Substring($trim.Length).TrimStart('/')
            $dest = Join-Path $OutDir ((ConvertTo-SafeFileName $rel) + ".$Format")

            if ($SkipExisting -and (Test-Path $dest) -and (Get-Item $dest).Length -ge 1024) {
                Write-Host ("[{0,2}/{1}] skip (exists)  {2}" -f $n, $docs.Count, $d.Path)
                continue
            }

            Write-Host ("[{0,2}/{1}] {2}" -f $n, $docs.Count, $d.Path) -NoNewline
            try {
                $r = Export-One -Doc $d -DocId $d.Id -Destination $dest
                Write-Host ("  -> {0} KB" -f $r.SizeKB)
                $r
            }
            catch {
                # One bad notebook must not abandon the other 34.
                Write-Host "  FAILED: $($_.Exception.Message)"
                [pscustomobject]@{
                    Path = $d.Path; Id = $d.Id; Format = $Format
                    File = $null; SizeKB = 0; Transport = $transportArg
                    Error = $_.Exception.Message
                }
            }
        }
    }
}
