<#
.SYNOPSIS
    Generates the public site from the catalogue.

.DESCRIPTION
    The site is derived, never hand-written. catalog.xml is the single source of truth,
    so the page a partner reads and the feed iDM3 reads cannot disagree.

    Produces:
        index.html              overview - latest firmware, counts, how to get it
        firmware/index.html     every model, with its published versions
        firmware/<MODEL>.html   one page per model, full version history
        compatibility.html      the recommended minimum versions matrix
        feed.xml                Atom feed of published firmware

.PARAMETER OutputPath
    Where to write the site. Defaults to _site/ (git-ignored).
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$SiteTitle = 'iDM3 Releases',
    [string]$RepoUrl = 'https://github.com/elkoep-dev/iDM3-releases'
)

$ErrorActionPreference = 'Stop'

$repoRoot    = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $repoRoot 'catalog.xml'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot '_site'
}

if (-not (Test-Path -LiteralPath $catalogPath)) {
    throw "catalog.xml not found. Run Build-Catalog.ps1 first."
}

$catalog = New-Object System.Xml.XmlDocument
$catalog.Load($catalogPath)

$items = @($catalog.FirmwareCatalog.Item | Where-Object { $null -ne $_ })
$flashable = @($items | Where-Object { $_.Kind -eq 'Firmware' })
$sequence = $catalog.FirmwareCatalog.Sequence
$generated = $catalog.FirmwareCatalog.Generated

# --- helpers ---------------------------------------------------------------------------
function Get-Escaped {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Security.SecurityElement]::Escape($Text)
}

$styleSheet = @'
:root{--bg:#f2f3f1;--card:#fff;--ink:#16191a;--muted:#5f6663;--line:#d6dad5;--accent:#c8102e;--slate:#2e4756}
@media(prefers-color-scheme:dark){:root{--bg:#131715;--card:#1b201e;--ink:#e9ece8;--muted:#939b96;--line:#2f3633;--accent:#ff6478;--slate:#8fb4c8}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 "Segoe UI",system-ui,sans-serif}
.wrap{max-width:1000px;margin:0 auto;padding:0 20px}
header{background:var(--card);border-bottom:1px solid var(--line)}
header .wrap{padding:28px 20px}
h1{margin:0 0 6px;font-size:1.9rem;letter-spacing:-.02em}
h2{margin:36px 0 14px;font-size:1.25rem;letter-spacing:-.01em}
.sub{color:var(--muted);margin:0}
nav{margin-top:16px;display:flex;gap:18px;flex-wrap:wrap}
nav a{color:var(--accent);text-decoration:none;font-weight:600;font-size:.92rem}
nav a:hover{text-decoration:underline}
main{padding-bottom:56px}
table{border-collapse:collapse;width:100%;background:var(--card);border:1px solid var(--line);border-radius:6px;overflow:hidden;font-size:.92rem}
th,td{text-align:left;padding:10px 13px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:.74rem;letter-spacing:.09em;text-transform:uppercase;color:var(--muted);font-weight:600}
tbody tr:last-child td{border-bottom:0}
code,.mono{font-family:"Cascadia Mono",Consolas,monospace;font-size:.86em}
a{color:var(--accent)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:22px 0}
.tile{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:15px}
.tile b{display:block;font-size:1.7rem;line-height:1.1;font-variant-numeric:tabular-nums}
.tile span{color:var(--muted);font-size:.8rem;text-transform:uppercase;letter-spacing:.07em}
.models{display:grid;grid-template-columns:repeat(auto-fill,minmax(155px,1fr));gap:8px;margin-top:8px}
.models a{background:var(--card);border:1px solid var(--line);border-radius:5px;padding:9px 11px;text-decoration:none;font-weight:600;font-size:.9rem;display:block}
.models a:hover{border-color:var(--accent)}
.models a em{display:block;color:var(--muted);font-weight:400;font-style:normal;font-size:.78rem;margin-top:2px}
ul.notes{margin:5px 0 0;padding-left:17px;color:var(--muted)}
.tag{display:inline-block;padding:2px 7px;border-radius:3px;font-size:.7rem;text-transform:uppercase;letter-spacing:.06em;background:var(--bg);color:var(--muted);border:1px solid var(--line)}
footer{border-top:1px solid var(--line);padding:22px 0;color:var(--muted);font-size:.85rem}
.warn{background:var(--card);border-left:3px solid var(--accent);padding:12px 15px;border-radius:0 5px 5px 0;margin:18px 0}
@media(max-width:560px){table{font-size:.85rem}th,td{padding:8px 9px}}
'@

function New-Page {
    param([string]$Title, [string]$Body, [string]$Root = '')

    return @"
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$(Get-Escaped $Title)</title>
<style>$styleSheet</style>
</head><body>
<header><div class="wrap">
<h1>$(Get-Escaped $SiteTitle)</h1>
<p class="sub">Firmware and releases for the iNELS BUS system</p>
<nav>
  <a href="${Root}index.html">Overview</a>
  <a href="${Root}firmware/index.html">Firmware</a>
  <a href="${Root}compatibility.html">Compatibility</a>
  <a href="$RepoUrl">Repository</a>
</nav>
</div></header>
<main class="wrap">
$Body
</main>
<footer><div class="wrap">
Generated from <code>catalog.xml</code> sequence $sequence on $generated.
Every archive is covered by a SHA-256 digest in the catalogue.
</div></footer>
</body></html>
"@
}

# --- output tree -------------------------------------------------------------------------
if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Recurse -Force }
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $OutputPath 'firmware') -Force | Out-Null

$utf8 = New-Object System.Text.UTF8Encoding($false)
$models = $flashable | Group-Object Model | Sort-Object Name

# --- per-model pages -----------------------------------------------------------------------
foreach ($group in $models) {
    $rows = ''
    foreach ($entry in ($group.Group | Sort-Object Version -Descending)) {
        $notes = ''
        $noteNodes = @($entry.SelectNodes('Note'))
        if ($noteNodes.Count -gt 0) {
            $noteItems = ($noteNodes | ForEach-Object { "<li>$(Get-Escaped $_.InnerText)</li>" }) -join ''
            $notes = "<ul class=`"notes`">$noteItems</ul>"
        }
        else {
            $notes = '<span class="tag">no release notes</span>'
        }

        $kb = [math]::Round([long]$entry.Size / 1024.0, 1)
        $rows += @"
<tr>
  <td class="mono"><strong>$(Get-Escaped $entry.Version)</strong></td>
  <td>$notes</td>
  <td class="mono">$kb kB</td>
  <td class="mono" style="word-break:break-all;font-size:.72rem;color:var(--muted)">$(Get-Escaped $entry.Sha256)</td>
</tr>
"@
    }

    $body = @"
<h2>$(Get-Escaped $group.Name)</h2>
<p class="sub">$($group.Count) published version$(if($group.Count -ne 1){'s'}). Newest first.</p>
<table><thead><tr><th>Version</th><th>Changes</th><th>Size</th><th>SHA-256</th></tr></thead>
<tbody>$rows</tbody></table>
<p style="margin-top:20px"><a href="index.html">&larr; All models</a></p>
"@

    $file = Join-Path $OutputPath "firmware\$($group.Name).html"
    [System.IO.File]::WriteAllText($file, (New-Page -Title "$($group.Name) firmware" -Body $body -Root '../'), $utf8)
}

# --- firmware index -------------------------------------------------------------------------
$cards = ''
foreach ($group in $models) {
    $newest = ($group.Group | Sort-Object Version -Descending | Select-Object -First 1).Version
    $cards += "<a href=`"$(Get-Escaped $group.Name).html`">$(Get-Escaped $group.Name)<em>$(Get-Escaped $newest) &middot; $($group.Count) version$(if($group.Count -ne 1){'s'})</em></a>"
}

$indexBody = @"
<h2>Firmware by device</h2>
<p class="sub">$($models.Count) models, $($flashable.Count) flashable firmware archives.</p>
<div class="models">$cards</div>
"@
[System.IO.File]::WriteAllText((Join-Path $OutputPath 'firmware\index.html'),
    (New-Page -Title 'Firmware' -Body $indexBody -Root '../'), $utf8)

# --- overview ---------------------------------------------------------------------------------
$latestRows = ''
foreach ($group in ($models | Sort-Object Name)) {
    $newest = $group.Group | Sort-Object Version -Descending | Select-Object -First 1
    $latestRows += "<tr><td><a href=`"firmware/$(Get-Escaped $group.Name).html`">$(Get-Escaped $group.Name)</a></td><td class=`"mono`">$(Get-Escaped $newest.Version)</td></tr>"
}

$definitionCount  = @($items | Where-Object { $_.Kind -eq 'Definition' }).Count
$placeholderCount = @($items | Where-Object { $_.Kind -eq 'Placeholder' }).Count

$overviewBody = @"
<div class="tiles">
  <div class="tile"><b>$($flashable.Count)</b><span>Firmware archives</span></div>
  <div class="tile"><b>$($models.Count)</b><span>Device models</span></div>
  <div class="tile"><b>$sequence</b><span>Catalogue sequence</span></div>
</div>

<h2>Getting firmware</h2>
<p>iDM3 downloads firmware from this repository automatically. Open the firmware manager,
check for updates, and the versions published here appear alongside the ones already
installed. Downloading before going on site is recommended - connectivity in plant rooms
is unreliable.</p>
<p>Every archive is covered by a SHA-256 digest inside <code>catalog.xml</code>, and iDM3
rejects an archive whose digest does not match, so a corrupted or substituted file is not
installed. iDM3 validates the HTTPS certificate of this host itself rather than relying on
whatever the machine happens to trust.</p>
<p>The catalogue is not signed. Authenticity rests on HTTPS and on who can publish here -
the same boundary firmware has always had, since the iDM3 installer is built from the same
source. It carries data only: files iDM3 reads, never executables it runs.</p>

<h2>Latest version per model</h2>
<table><thead><tr><th>Model</th><th>Latest</th></tr></thead><tbody>$latestRows</tbody></table>

<h2>What else is in the catalogue</h2>
<p class="sub">Not every entry is flashable firmware. iDM3 only ever offers the first kind.</p>
<table><thead><tr><th>Kind</th><th>Count</th><th>What it is</th></tr></thead><tbody>
<tr><td class="mono">Firmware</td><td class="mono">$($flashable.Count)</td><td>Carries a <code>.if3</code> or <code>.nf3</code> image</td></tr>
<tr><td class="mono">Definition</td><td class="mono">$definitionCount</td><td>Only <code>unit.xml</code> - a device model, nothing to flash</td></tr>
<tr><td class="mono">Placeholder</td><td class="mono">$placeholderCount</td><td>Empty archive for a virtual module inside the central unit</td></tr>
</tbody></table>
"@
[System.IO.File]::WriteAllText((Join-Path $OutputPath 'index.html'),
    (New-Page -Title $SiteTitle -Body $overviewBody), $utf8)

# --- compatibility ------------------------------------------------------------------------------
$compatPath = Join-Path $repoRoot 'compatibility.txt'
$compatBody = ''
if (Test-Path -LiteralPath $compatPath) {
    $raw = Get-Content -LiteralPath $compatPath -Raw
    $compatBody = @"
<h2>Recommended minimum versions</h2>
<p class="sub">The combination ELKO EP tests and supports. Running below these is not recommended.</p>
<pre style="background:var(--card);border:1px solid var(--line);border-radius:6px;padding:16px;overflow-x:auto"><code>$(Get-Escaped $raw)</code></pre>
"@
}
else {
    $compatBody = @"
<h2>Recommended minimum versions</h2>
<div class="warn">The compatibility matrix has not been published yet. Add
<code>compatibility.txt</code> to the repository - the content is maintained in
<code>Recommended minimal firmware version.txt</code>, which ships inside iDM3.</div>
"@
}
[System.IO.File]::WriteAllText((Join-Path $OutputPath 'compatibility.html'),
    (New-Page -Title 'Compatibility' -Body $compatBody), $utf8)

# --- Atom feed -------------------------------------------------------------------------------------
$entries = ''
foreach ($group in ($models | Sort-Object Name)) {
    $newest = $group.Group | Sort-Object Version -Descending | Select-Object -First 1
    $summary = (@($newest.SelectNodes('Note')) | ForEach-Object { $_.InnerText }) -join '; '
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = 'Published firmware.' }
    $entries += @"
  <entry>
    <title>$(Get-Escaped "$($group.Name) $($newest.Version)")</title>
    <id>urn:inels:firmware:$(Get-Escaped $group.Name):$(Get-Escaped $newest.Version)</id>
    <updated>$generated</updated>
    <summary>$(Get-Escaped $summary)</summary>
  </entry>
"@
}
$feed = @"
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>$(Get-Escaped $SiteTitle)</title>
  <id>urn:inels:idm3-releases</id>
  <updated>$generated</updated>
$entries
</feed>
"@
[System.IO.File]::WriteAllText((Join-Path $OutputPath 'feed.xml'), $feed, $utf8)

# --- report ------------------------------------------------------------------------------------------
$pageCount = @(Get-ChildItem -LiteralPath $OutputPath -Filter *.html -Recurse).Count
Write-Output ""
Write-Output "Site        : $OutputPath"
Write-Output "Pages       : $pageCount"
Write-Output "Models      : $($models.Count)"
Write-Output "Firmware    : $($flashable.Count)"
Write-Output "Open        : $(Join-Path $OutputPath 'index.html')"
