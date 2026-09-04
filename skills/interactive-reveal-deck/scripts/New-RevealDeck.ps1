<#
.SYNOPSIS
    Scaffold an interactive reveal.js deck from the skill's assets.

.DESCRIPTION
    Copies assets/ to the target folder, installs reveal.js and http-server
    locally (so the deck presents with no network), and writes a start script
    next to the deck.

    Refuses to overwrite an existing deck unless -Force, and never touches
    node_modules.

.EXAMPLE
    New-RevealDeck.ps1 -Path D:\talks\my-talk\deck -Title "My Talk"

.EXAMPLE
    New-RevealDeck.ps1 -Path .\deck -Title "Kafka for .NET devs" `
        -Parts 'intro:Intro','ingest:Ingest','stream:Streaming','ops:Operations'
#>
[CmdletBinding()]
param(
    # Where to create the deck. Created if missing.
    [Parameter(Mandatory)]
    [string]$Path,

    # Deck title: goes into <title> and the title slide.
    [string]$Title = 'My presentation',

    # Parts, in order, as 'id:Label' or 'id:Label:#accent:#accent2'.
    # `id` must match the data-part attribute you put on each <section>.
    [string[]]$Parts,

    # Port the generated start script serves on.
    [int]$Port = 8081,

    # Overwrite index.html, css/ and js/ in an existing deck folder.
    [switch]$Force,

    # Copy the files but skip `npm install`.
    [switch]$NoInstall
)

$ErrorActionPreference = 'Stop'

$assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
if (-not (Test-Path $assets)) {
    throw "Cannot find the skill's assets folder at $assets"
}

# --- default accents ------------------------------------------------------
# Chosen to stay legible on the dark ground at projector gamma, and to read as
# a progression rather than a set. Used as a FOREGROUND colour in the rail and
# the part pill, so very dark values will not work.
$defaultAccents = @(
    @('#8b5cf6', '#22d3ee'),   # violet
    @('#22d3ee', '#60a5fa'),   # cyan
    @('#fbbf24', '#fb923c'),   # amber
    @('#fb7185', '#f472b6'),   # rose
    @('#34d399', '#22d3ee'),   # emerald
    @('#a78bfa', '#818cf8')    # indigo
)

if (-not $Parts -or $Parts.Count -eq 0) {
    # four parts, matching the four the template's slides use
    $Parts = @('intro:Intro', 'one:Part one', 'two:Part two', 'three:Part three')
}

$partObjects = @()
for ($i = 0; $i -lt $Parts.Count; $i++) {
    $bits = $Parts[$i] -split ':', 4
    if ($bits.Count -lt 2 -or -not $bits[0] -or -not $bits[1]) {
        throw "Part '$($Parts[$i])' must be 'id:Label' or 'id:Label:#accent:#accent2'"
    }
    $fallback = $defaultAccents[$i % $defaultAccents.Count]

    $accent = $fallback[0]
    if ($bits.Count -ge 3 -and $bits[2]) { $accent = $bits[2].Trim() }
    $accent2 = $fallback[1]
    if ($bits.Count -ge 4 -and $bits[3]) { $accent2 = $bits[3].Trim() }

    $partObjects += New-Object psobject -Property @{
        id      = $bits[0].Trim()
        label   = $bits[1].Trim()
        accent  = $accent
        accent2 = $accent2
    }
}

# --- copy -----------------------------------------------------------------
if ((Test-Path (Join-Path $Path 'index.html')) -and -not $Force) {
    throw "$Path already contains a deck. Re-run with -Force to overwrite index.html, css/ and js/ (node_modules is never touched)."
}

New-Item -ItemType Directory -Force -Path $Path | Out-Null
$Path = (Resolve-Path $Path).Path

Write-Host "Scaffolding deck in $Path" -ForegroundColor Cyan
foreach ($item in 'index.html', 'package.json', '.gitignore') {
    Copy-Item (Join-Path $assets $item) -Destination $Path -Force
}
foreach ($dir in 'css', 'js') {
    New-Item -ItemType Directory -Force -Path (Join-Path $Path $dir) | Out-Null
    Copy-Item (Join-Path $assets "$dir\*") -Destination (Join-Path $Path $dir) -Force
}

# --- personalise index.html ----------------------------------------------
# Plain string replacement against the known template markers: less to go
# wrong than regexing HTML, and it fails loudly (below) if a marker moved.
$indexPath = Join-Path $Path 'index.html'
$html = Get-Content $indexPath -Raw

$markers = @(
    @{ From = '<title>DECK TITLE — subtitle</title>';            To = "<title>$Title</title>" },
    @{ From = '<h1>The deck title<br>on two lines</h1>';         To = "<h1>$Title</h1>" },
    @{ From = '<h2>The deck title</h2>';                         To = "<h2>$Title</h2>" }
)
foreach ($m in $markers) {
    if ($html.Contains($m.From)) {
        $html = $html.Replace($m.From, $m.To)
    } else {
        Write-Warning "Template marker not found, left as-is: $($m.From)"
    }
}

$partLines = @()
foreach ($p in $partObjects) {
    $partLines += "      { id: '$($p.id)', label: '$($p.label)', accent: '$($p.accent)', accent2: '$($p.accent2)' }"
}
$nl = [Environment]::NewLine
$partsBlock = "    window.DECK_PARTS = [$nl" + ($partLines -join ",$nl") + "$nl    ];"

$partsPattern = '(?s)    window\.DECK_PARTS = \[.*?\r?\n    \];'
if ([regex]::IsMatch($html, $partsPattern)) {
    # escape $ so it is not read as a regex substitution
    $html = [regex]::Replace($html, $partsPattern, $partsBlock.Replace('$', '$$'))
} else {
    Write-Warning 'Could not find the window.DECK_PARTS block — set your parts by hand in index.html.'
}

# --- retarget the template's data-part attributes -------------------------
# The template's own part ids (intro/one/two/three) would otherwise not match
# the ids supplied here, and every slide would silently fall back to part one.
# Mapped positionally, in the order the ids first appear in the template.
$templateIds = @()
foreach ($m in [regex]::Matches($html, 'data-part="([^"]+)"')) {
    $id = $m.Groups[1].Value
    if ($templateIds -notcontains $id) { $templateIds += $id }
}

$mapCount = [Math]::Min($templateIds.Count, $partObjects.Count)
if ($mapCount -gt 0) {
    # Two passes via a placeholder: a single pass can collide when a NEW id is
    # also an OLD id still waiting to be renamed.
    for ($i = 0; $i -lt $mapCount; $i++) {
        $html = $html.Replace(('data-part="' + $templateIds[$i] + '"'), ('data-part="@@part' + $i + '@@"'))
    }
    for ($i = 0; $i -lt $mapCount; $i++) {
        $html = $html.Replace(('data-part="@@part' + $i + '@@"'), ('data-part="' + $partObjects[$i].id + '"'))
    }
}

if ($templateIds.Count -gt $partObjects.Count) {
    $unmapped = ($templateIds[$partObjects.Count..($templateIds.Count - 1)]) -join ', '
    Write-Warning "The template has more parts than you supplied. Slides still using data-part=$unmapped fall back to the first part - reassign or delete them."
}

Set-Content -Path $indexPath -Value $html -NoNewline -Encoding UTF8

# --- package.json port ----------------------------------------------------
if ($Port -ne 8081) {
    $pkgPath = Join-Path $Path 'package.json'
    (Get-Content $pkgPath -Raw).Replace('-p 8081', "-p $Port") |
        Set-Content -Path $pkgPath -NoNewline -Encoding UTF8
}

# --- start script, next to the deck --------------------------------------
$deckLeaf = Split-Path $Path -Leaf
$startPath = Join-Path (Split-Path $Path -Parent) 'start-deck.ps1'
@"
# Serves the interactive reveal.js deck on http://localhost:$Port
param([int]`$Port = $Port, [switch]`$NoBrowser)

`$deck = Join-Path `$PSScriptRoot '$deckLeaf'

if (-not (Test-Path (Join-Path `$deck 'node_modules/reveal.js'))) {
    Write-Host 'Installing deck dependencies (first run only)...' -ForegroundColor Yellow
    Push-Location `$deck; npm install; Pop-Location
}

Write-Host "Serving the deck on http://localhost:`$Port/index.html" -ForegroundColor Cyan
Write-Host '  ?  keyboard help     /  jump to a slide     B  run demo     S  speaker notes' -ForegroundColor DarkGray

Push-Location `$deck
try {
    if (`$NoBrowser) { npx http-server . -p `$Port -c-1 }
    else { npx http-server . -p `$Port -c-1 -o /index.html }
} finally { Pop-Location }
"@ | Set-Content -Path $startPath -Encoding UTF8

# --- install --------------------------------------------------------------
if (-not $NoInstall) {
    Write-Host 'Installing reveal.js + http-server locally...' -ForegroundColor Cyan
    Push-Location $Path
    try {
        npm install --silent
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "npm install exited $LASTEXITCODE — run it by hand in $Path"
        }
    } finally { Pop-Location }
}

$partIds = ($partObjects | ForEach-Object { $_.id }) -join ', '
Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host "  deck      $Path"
Write-Host "  serve     $startPath"
Write-Host "  parts     $partIds"
Write-Host ''
Write-Host 'Next: edit index.html. It ships with one of every component and two' -ForegroundColor DarkGray
Write-Host 'working widgets - delete what you do not need.' -ForegroundColor DarkGray
