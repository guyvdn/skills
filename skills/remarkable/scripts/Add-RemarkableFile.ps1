<#
.SYNOPSIS
    Upload a PDF or EPUB to a connected reMarkable over the USB web interface.

.DESCRIPTION
    The tablet's /upload endpoint drops the file into whichever folder was
    listed most recently, so this lists the destination first and then posts.

    Works under a VPN that has stolen the 10.11.99.0/27 route: the transport
    binds to the tablet's own interface rather than trusting the route table.
    No admin rights needed. See references/troubleshooting.md.

.EXAMPLE
    .\Add-RemarkableFile.ps1 -Path .\Standup.pdf
    .\Add-RemarkableFile.ps1 -Path .\Standup.pdf -Folder 'Templates'
    .\Add-RemarkableFile.ps1 -Path .\*.pdf -Folder 'Templates'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string[]] $Path,

    # Destination folder path on the tablet, e.g. 'Archive/Project X'.
    # Omit for the root folder. The folder must already exist.
    [string] $Folder,

    [int] $TimeoutSec = 300
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RemarkableWeb.ps1')
$listScript = Join-Path $PSScriptRoot 'Get-RemarkableDocs.ps1'
$base = 'http://10.11.99.1'

# ---- resolve the destination folder to a GUID -------------------------------

$targetUri = "$base/documents/"
if ($Folder) {
    $trim = $Folder.Trim('/')
    $all = & $listScript -Transport usb -Json | ConvertFrom-Json
    $hit = @($all | Where-Object { $_.Kind -eq 'folder' -and $_.Path -eq $trim })
    if ($hit.Count -eq 0) {
        $hit = @($all | Where-Object { $_.Kind -eq 'folder' -and $_.Path -like "*$trim" })
    }
    if ($hit.Count -eq 0) { throw "No folder '$Folder' on the tablet. Create it there first." }
    if ($hit.Count -gt 1) {
        throw "'$Folder' matches $($hit.Count) folders:`n" + (($hit | ForEach-Object { "  $($_.Path)" }) -join "`n")
    }
    $targetUri = "$base/documents/$($hit[0].Id)"
    Write-Verbose "Destination: $($hit[0].Path)"
}

# ---- upload -----------------------------------------------------------------

$files = @()
foreach ($p in $Path) { $files += @(Get-Item $p -ErrorAction Stop) }

foreach ($f in $files) {
    if ($f.Extension -notin '.pdf', '.epub') {
        Write-Warning "Skipping $($f.Name) — the tablet accepts only .pdf and .epub."
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($f.Name, "upload to $($Folder ? $Folder : 'root') on the reMarkable")) {
        continue
    }

    # Re-list immediately before each post: the endpoint targets the folder
    # listed last, and anything else touching the interface would move it.
    $null = Invoke-RmJson -Uri $targetUri -TimeoutSec 20

    $r = Send-RmFile -Path $f.FullName -TimeoutSec $TimeoutSec

    [pscustomobject]@{
        File       = $f.Name
        SizeKB     = [math]::Round($f.Length / 1KB, 1)
        Folder     = if ($Folder) { $Folder } else { '/' }
        StatusCode = $r.StatusCode
        Via        = $r.Via
    }
}
