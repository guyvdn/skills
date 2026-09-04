<#
.SYNOPSIS
    Shared HTTP helpers for the reMarkable USB web interface. Dot-source it.

.DESCRIPTION
    Three things the naive call gets wrong, all handled here:

    1. A VPN commonly claims 10.11.99.0/27 at a better metric than the tablet's
       own adapter, so every request times out while the cable and driver are
       perfectly fine. Binding the *source address* to the tablet's interface
       makes Windows pick the right egress and bypasses the stolen route, with
       no admin rights and without disconnecting the VPN. PowerShell cannot
       bind a source address, but curl.exe (shipped with Windows 10+) can, so
       these helpers fall back to it automatically.

    2. The tablet declares charset=ISO-8859-1 and then sends UTF-8. Every
       response is decoded as UTF-8 explicitly.

    3. A corporate proxy will happily try to resolve 10.11.99.1 upstream.
       Every call opts out of the proxy.
#>

$script:RmBaseUrl = 'http://10.11.99.1'

function Get-RmBindAddress {
    <#  The host's own address on the tablet's USB network, or $null.
        Cached, because enumerating adapters on every request is wasteful. #>
    if ($script:RmBindCached) { return $script:RmBindCached }
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -like '10.11.99.*' -and $_.IPAddress -ne '10.11.99.1' } |
          Select-Object -First 1 -ExpandProperty IPAddress
    $script:RmBindCached = $ip
    return $ip
}

function Test-RmRouteHijacked {
    <#  True when something other than the tablet's own adapter owns the route.
        Used only to explain the failure, never to decide what to do. #>
    $bind = Get-RmBindAddress
    if (-not $bind) { return $false }
    $r = Find-NetRoute -RemoteIPAddress '10.11.99.1' -ErrorAction SilentlyContinue |
         Select-Object -First 1
    return ($r -and $r.IPAddress -ne $bind)
}

function Get-RmCurl {
    $c = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $sys = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $sys) { return $sys }
    return $null
}

function Resolve-RmTransport {
    <#  Decide ONCE how to reach the tablet, and remember it.

        Probing per request is what makes this slow: when a VPN owns the route,
        the PowerShell attempt burns its full timeout before the fallback runs,
        and a recursive tree walk pays that on every folder. One 4-second probe
        up front costs a fraction of that and the answer never changes mid-run.

        Returns 'powershell' or 'curl'. #>
    if ($script:RmTransport) { return $script:RmTransport }

    $probe = "$script:RmBaseUrl/documents/"
    try {
        $splat = @{ Uri = $probe; TimeoutSec = 4; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $splat['NoProxy'] = $true }
        $null = Invoke-WebRequest @splat
        $script:RmTransport = 'powershell'
    }
    catch {
        $bind = Get-RmBindAddress
        $curl = Get-RmCurl
        if ($bind -and $curl) {
            # -o NUL, not -o $null: PowerShell turns $null into an empty string
            # and curl then fails on the empty output path, so the probe would
            # always report failure and quietly fall back to the cloud.
            $code = & $curl --interface $bind --noproxy '*' -s -m 5 -o NUL -w '%{http_code}' $probe
            if ($code -eq '200') {
                Write-Verbose "Direct route to the tablet is unusable; binding to $bind instead."
                $script:RmTransport = 'curl'
            }
        }
        if (-not $script:RmTransport) { $script:RmTransport = 'powershell' }  # let the real call report why
    }
    return $script:RmTransport
}

function Invoke-RmBytes {
    <#  GET a URL, return raw bytes, over whichever transport actually works. #>
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [int] $TimeoutSec = 20
    )

    if ((Resolve-RmTransport) -eq 'curl') {
        $bind = Get-RmBindAddress
        $curl = Get-RmCurl
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            $code = & $curl --interface $bind --noproxy '*' -s -m $TimeoutSec `
                            -o $tmp -w '%{http_code}' $Uri
            if ($LASTEXITCODE -ne 0 -or $code -ne '200') {
                throw "GET $Uri failed via curl --interface $bind (exit $LASTEXITCODE, HTTP $code)"
            }
            return [System.IO.File]::ReadAllBytes($tmp)
        }
        finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    $splat = @{ Uri = $Uri; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $splat['NoProxy'] = $true }
    $resp = Invoke-WebRequest @splat

    if ($resp.RawContentStream) {
        $ms = New-Object System.IO.MemoryStream
        $resp.RawContentStream.Position = 0
        $resp.RawContentStream.CopyTo($ms)
        return $ms.ToArray()
    }
    if ($resp.Content -is [byte[]]) { return $resp.Content }     # PS 5.1
    return [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes($resp.Content)
}

function Invoke-RmJson {
    param([Parameter(Mandatory)] [string] $Uri, [int] $TimeoutSec = 20)
    $bytes = Invoke-RmBytes -Uri $Uri -TimeoutSec $TimeoutSec
    [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
}

function Save-RmFile {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $OutFile,
        [int] $TimeoutSec = 600
    )
    $bytes = Invoke-RmBytes -Uri $Uri -TimeoutSec $TimeoutSec
    [System.IO.File]::WriteAllBytes($OutFile, $bytes)
}

function Send-RmFile {
    <#  POST a file to /upload. It lands in whichever folder was listed last,
        so list the destination immediately before calling this. #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $TimeoutSec = 300
    )

    $Path = (Resolve-Path $Path).Path

    if ((Resolve-RmTransport) -eq 'curl') {
        $bind = Get-RmBindAddress
        $curl = Get-RmCurl
        $body = & $curl --interface $bind --noproxy '*' -s -m $TimeoutSec `
                        -w "`n%{http_code}" `
                        -H "Origin: $script:RmBaseUrl" -H "Referer: $script:RmBaseUrl/" `
                        -F "file=@$Path" "$script:RmBaseUrl/upload"
        $lines = @($body -split "`n")
        $code = $lines[-1].Trim()
        if ($code -notin '200', '201') {
            throw "Upload of $Path failed via curl --interface $bind : HTTP $code — $($lines[0])"
        }
        return [pscustomobject]@{
            StatusCode = [int]$code
            Body       = ($lines[0..($lines.Count - 2)] -join "`n")
            Via        = "curl --interface $bind"
        }
    }

    $splat = @{
        Uri = "$script:RmBaseUrl/upload"; Method = 'Post'
        Headers = @{ Origin = $script:RmBaseUrl; Referer = "$script:RmBaseUrl/" }
        Form = @{ file = Get-Item $Path }
        TimeoutSec = $TimeoutSec; ErrorAction = 'Stop'
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $splat['NoProxy'] = $true }
    $r = Invoke-WebRequest @splat
    [pscustomobject]@{ StatusCode = $r.StatusCode; Body = $r.Content; Via = 'powershell' }
}
