<#
.SYNOPSIS
    Builds catalog.xml from firmwares/ and notes/.

.DESCRIPTION
    catalog.xml is the index iDM3 reads. It lists every published artifact with its
    SHA-256, so the catalogue alone determines whether a downloaded archive is intact.

    The catalogue is not signed. Authenticity rests on HTTPS to the repository host and on
    who can push to it - the same trust boundary the installer-shipped firmware already
    had. iDM3 validates the certificate itself rather than inheriting the application's
    permissive global callback. See the trust model in README.md.

    The catalogue is path-based rather than firmware-specific: each Item carries the Target
    path it belongs at inside the iDM3 installation. Firmware is simply the first component
    to use it - Images, Languages or Documentation can be added later without changing the
    schema or the client.

    Three kinds of entry are recorded, because Firmwares/ has always held three different
    things and only one of them can be flashed:

        Firmware     a .if3 / .nf3 image
        Definition   only unit.xml - a device model, nothing to flash
        Placeholder  an empty archive - a virtual module inside the central unit

    iDM3 offers Kind="Firmware" and nothing else.

.PARAMETER ValidDays
    How long clients should accept this catalogue before warning that it is stale. This
    bounds a rollback: an old catalogue cannot be replayed indefinitely.

.EXAMPLE
    .\tools\Build-Catalog.ps1
#>
[CmdletBinding()]
param(
    [int]$ValidDays = 180,
    [string]$Channel = 'Stable',

    # Version of iDM3 that produced this payload, e.g. 3.6.1. Stamped onto every entry
    # except firmware, so an older installation skips content written for a newer tool
    # rather than applying it and failing somewhere else entirely.
    #
    # Firmware is deliberately exempt: it is versioned per device and read by a central
    # unit that validates it, and reaching older installations is the point of publishing
    # it at all.
    [string]$MinAppVersion = '',

    # Overrides the automatic increment. Only for recovering from an unreadable
    # catalog.xml - it must still be above whatever is published.
    [int]$Sequence = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot      = Split-Path -Parent $PSScriptRoot
$firmwareDir   = Join-Path $repoRoot 'firmwares'
$notesDir      = Join-Path $repoRoot 'notes'
$contentDir    = Join-Path $repoRoot 'content'
$catalogPath   = Join-Path $repoRoot 'catalog.xml'
$aliasPath     = Join-Path $notesDir 'model-aliases.xml'

# --- Sequence: strictly increasing, so a client can refuse to move backwards -----------
# XmlDocument.Load rather than the [xml] cast: the cast's exception message embeds the
# whole document, which buries the actual problem when the file is 56 KB.
# $nextSequence, not $sequence: PowerShell variable names are case-insensitive, so a
# local named $sequence would BE the -Sequence parameter and silently overwrite it.
$nextSequence = 1

# Kept so a build that changes nothing can put the published number back, rather than
# advancing it for a catalogue that turns out to be identical.
$publishedSequence = 0

if ($Sequence -gt 0) {
    $nextSequence = $Sequence
}
elseif (Test-Path -LiteralPath $catalogPath) {
    $previous = New-Object System.Xml.XmlDocument
    try {
        $previous.Load($catalogPath)
        $publishedSequence = [int]$previous.FirmwareCatalog.Sequence
        $nextSequence = $publishedSequence + 1
    }
    catch {
        $reason = $_.Exception.Message
        if ($reason.Length -gt 200) { $reason = $reason.Substring(0, 200) + '...' }
        throw "The existing catalog.xml is unreadable, so the next Sequence cannot be determined: $reason`n" +
              "Fix or delete catalog.xml, or pass -Sequence with a value above the published one. " +
              "Never reuse or lower a Sequence - clients reject a catalogue that moves backwards."
    }
}

# --- Model aliases --------------------------------------------------------------------
$aliases     = @{}
$unconfirmed = New-Object System.Collections.Generic.List[string]
if (Test-Path -LiteralPath $aliasPath) {
    $aliasXml = [xml](Get-Content -LiteralPath $aliasPath -Raw)
    foreach ($a in @($aliasXml.ModelAliases.Alias)) {
        if ($null -eq $a) { continue }
        $aliases[$a.Firmware] = $a.Notes
        if ($a.Confirmed -ne 'true') { $unconfirmed.Add("$($a.Firmware) -> $($a.Notes)") }
    }
}

# --- Release notes --------------------------------------------------------------------
$notes = @{}
foreach ($noteFile in Get-ChildItem -LiteralPath $notesDir -Filter *.xml -File -ErrorAction SilentlyContinue) {
    if ($noteFile.Name -eq 'model-aliases.xml') { continue }
    $noteXml = [xml](Get-Content -LiteralPath $noteFile.FullName -Raw)
    $model   = $noteXml.ReleaseNotes.Model
    foreach ($release in @($noteXml.ReleaseNotes.Release)) {
        if ($null -eq $release) { continue }
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($n in @($release.Note)) {
            if ($null -eq $n) { continue }
            $list.Add(@{ Lang = $n.Lang; Text = $n.InnerText })
        }
        if ($list.Count -gt 0) { $notes["$model|$($release.Version)"] = $list }
    }
}

# --- Scan the firmware directory ------------------------------------------------------
$pattern = '^(?<model>[A-Za-z0-9][A-Za-z0-9\-]*)_(?<version>[0-9A-F]{2}\.[0-9A-F]{2}\.[0-9A-F]{2})\.zip$'
$items   = New-Object System.Collections.Generic.List[object]
$noNotes = New-Object System.Collections.Generic.List[string]
$sha     = [System.Security.Cryptography.SHA256]::Create()

try {
    foreach ($file in Get-ChildItem -LiteralPath $firmwareDir -Filter *.zip -File | Sort-Object Name) {
        $m = [regex]::Match($file.Name, $pattern)
        if (-not $m.Success) {
            throw "$($file.Name) does not match MODEL_MM.mm.pp.zip - run Test-FirmwareNames.ps1"
        }

        $model   = $m.Groups['model'].Value
        $version = $m.Groups['version'].Value

        if ($file.Length -le 22) {
            $kind = 'Placeholder'
        }
        else {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
            try {
                $hasImage = @($zip.Entries | Where-Object { $_.Name -match '\.(if3|nf3)$' }).Count -gt 0
                $kind = if ($hasImage) { 'Firmware' } else { 'Definition' }
            }
            finally { $zip.Dispose() }
        }

        $stream = [System.IO.File]::OpenRead($file.FullName)
        try {
            $digest = -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
        }
        finally { $stream.Dispose() }

        # Follow an alias when the history file uses a different model name.
        $notesModel = if ($aliases.ContainsKey($model)) { $aliases[$model] } else { $model }
        $entryNotes = $notes["$notesModel|$version"]
        if ($null -eq $entryNotes -and $kind -eq 'Firmware') {
            $noNotes.Add("$model $version")
        }

        $items.Add([pscustomobject]@{
            Kind    = $kind
            Model   = $model
            Version = $version
            Target  = "Firmwares\$($file.Name)"
            Source  = "firmwares/$($file.Name)"
            Size    = $file.Length
            Sha256  = $digest
            Notes   = $entryNotes
        })
    }

    # --- Scan content/ ----------------------------------------------------------------
    # Everything that is not firmware: languages, IDM.config, firmDepends.xml. The tree
    # under content/ mirrors the layout inside an iDM3 installation, so the path a file
    # sits at here is the path it belongs at there - content/Languages/x.lang becomes
    # Languages\x.lang. Nothing has to be registered anywhere to add one.
    #
    # These files are not versioned per device the way firmware is, so they carry the
    # MinAppVersion of the release that published them and an older installation skips
    # them. Publishing content without -MinAppVersion is refused rather than guessed at.
    if (Test-Path -LiteralPath $contentDir) {
        # -Force because the definition parts live in .config-overlay, and a leading dot
        # makes a directory hidden on Linux - where this runs in CI. Without it the parts
        # were committed to the repository and silently left out of the catalogue, so no
        # installation ever fetched them.
        $contentFiles = @(Get-ChildItem -LiteralPath $contentDir -File -Recurse -Force | Sort-Object FullName)

        if ($contentFiles.Count -gt 0 -and [string]::IsNullOrWhiteSpace($MinAppVersion)) {
            throw "content/ holds $($contentFiles.Count) file(s) but -MinAppVersion was not supplied. Content that is not versioned per device needs a floor, or an older iDM3 will apply it and fail somewhere else."
        }

        $contentRoot = (Resolve-Path -LiteralPath $contentDir).Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar)

        foreach ($file in $contentFiles) {
            $relative = $file.FullName.Substring($contentRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
            $relative = $relative -replace '\\', '/'

            $stream = [System.IO.File]::OpenRead($file.FullName)
            try {
                $digest = -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
            }
            finally { $stream.Dispose() }

            # The first path segment names the component, so Languages/ and Documentation/
            # arrive as themselves. A file directly under content/ belongs to the root.
            $segments  = $relative -split '/'
            $component = if ($segments.Count -gt 1) { $segments[0] } else { 'Root' }

            $items.Add([pscustomobject]@{
                Kind      = 'Content'
                Component = $component
                Model     = $relative
                Version   = $MinAppVersion
                Target    = ($relative -replace '/', '\')
                Source    = "content/$relative"
                Size      = $file.Length
                Sha256    = $digest
                Notes     = $null
            })
        }
    }
}
finally { $sha.Dispose() }

# --- Write the catalogue --------------------------------------------------------------
$generated  = [DateTime]::UtcNow
$validUntil = $generated.AddDays($ValidDays)

$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent       = $true
$settings.IndentChars  = '  '
$settings.Encoding     = New-Object System.Text.UTF8Encoding($false)
$settings.NewLineChars = "`n"

# Written to a temporary file first so the result can be compared with what is already
# published. Sequence and the timestamps move on every run by design, so a catalogue
# regenerated from unchanged inputs still differs textually - and CI would commit that,
# burning a sequence number and adding a commit that published nothing.
$pendingPath = "$catalogPath.pending"

$writer = [System.Xml.XmlWriter]::Create($pendingPath, $settings)
try {
    $writer.WriteStartElement('FirmwareCatalog')
    $writer.WriteAttributeString('Schema', '1')
    $writer.WriteAttributeString('Sequence', $nextSequence.ToString())
    $writer.WriteAttributeString('Generated', $generated.ToString('yyyy-MM-ddTHH:mm:ssZ'))
    $writer.WriteAttributeString('ValidUntil', $validUntil.ToString('yyyy-MM-ddTHH:mm:ssZ'))

    foreach ($item in $items) {
        # Firmwares is the only component so far. It is read from the item rather than
        # written literally, so adding Languages or Config later changes the scan, not this.
        $component = if ($item.Component) { $item.Component } else { 'Firmwares' }

        $writer.WriteStartElement('Item')
        $writer.WriteAttributeString('Component', $component)
        $writer.WriteAttributeString('Kind', $item.Kind)
        $writer.WriteAttributeString('Model', $item.Model)
        $writer.WriteAttributeString('Version', $item.Version)
        $writer.WriteAttributeString('Target', $item.Target)
        $writer.WriteAttributeString('Source', $item.Source)
        $writer.WriteAttributeString('Size', $item.Size.ToString())
        $writer.WriteAttributeString('Sha256', $item.Sha256)
        $writer.WriteAttributeString('Channel', $Channel)

        # Firmware carries no floor: it must reach installations older than the release
        # that published it. Everything else does, once other components are added here.
        if (-not [string]::IsNullOrWhiteSpace($MinAppVersion) -and $component -ne 'Firmwares') {
            $writer.WriteAttributeString('MinAppVersion', $MinAppVersion)
        }

        if ($null -ne $item.Notes) {
            foreach ($n in $item.Notes) {
                $writer.WriteStartElement('Note')
                $writer.WriteAttributeString('Lang', $n.Lang)
                $writer.WriteString($n.Text)
                $writer.WriteEndElement()
            }
        }
        $writer.WriteEndElement()
    }
    $writer.WriteEndElement()
}
finally { $writer.Close() }

# --- Keep it only if something actually changed -------------------------------------------
# Compared with the header stripped, because Sequence, Generated and ValidUntil move on
# every run whatever the inputs were. If the items are identical the published catalogue
# stays exactly as it is: the sequence number then counts publications rather than builds,
# and CI stops committing regenerations that published nothing.
function Get-CatalogBody {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path)
    return [regex]::Replace($text, '<FirmwareCatalog[^>]*>', '<FirmwareCatalog>')
}

$changed = (Get-CatalogBody $pendingPath) -ne (Get-CatalogBody $catalogPath)

if ($changed) {
    Move-Item -LiteralPath $pendingPath -Destination $catalogPath -Force
}
else {
    Remove-Item -LiteralPath $pendingPath -Force
    $nextSequence = $publishedSequence
}

# --- Report -----------------------------------------------------------------------------
Write-Output ""
Write-Output "Catalogue   : $catalogPath"
Write-Output "Sequence    : $nextSequence$(if (-not $changed) { ' (unchanged - nothing to publish)' })"
Write-Output "Valid until : $($validUntil.ToString('yyyy-MM-dd'))"
Write-Output "Items       : $($items.Count)"
foreach ($g in ($items | Group-Object Kind | Sort-Object Name)) {
    Write-Output ("                {0,-12} {1}" -f $g.Name, $g.Count)
}

if ($noNotes.Count -gt 0) {
    Write-Output ""
    Write-Warning "$($noNotes.Count) flashable firmware entries have no release notes."
}

if ($unconfirmed.Count -gt 0) {
    Write-Warning "$($unconfirmed.Count) model aliases are unconfirmed - a wrong one shows the notes of a different product."
}
