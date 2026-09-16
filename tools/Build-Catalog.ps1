<#
.SYNOPSIS
    Builds catalog.xml from firmwares/ and notes/, and optionally signs it.

.DESCRIPTION
    catalog.xml is the only file iDM3 has to trust. It lists every published artifact with
    its SHA-256, so one signature over this file covers every archive in the repository.

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

.PARAMETER PrivateKeyPath
    RSA private key in .NET XML form, produced by New-SigningKey.ps1. When omitted the
    catalogue is written unsigned, which is useful while iterating but must never be what
    gets published - Test-Catalog.ps1 and CI both reject an unsigned catalogue.

.PARAMETER ValidDays
    How long clients should accept this catalogue before warning that it is stale. This
    bounds a rollback: an old catalogue cannot be replayed indefinitely.

.EXAMPLE
    .\tools\Build-Catalog.ps1 -PrivateKeyPath E:\offline\idm3-catalog-active.private.xml
#>
[CmdletBinding()]
param(
    [string]$PrivateKeyPath,
    [int]$ValidDays = 180,
    [string]$Channel = 'Stable',

    # Overrides the automatic increment. Only for recovering from an unreadable
    # catalog.xml - it must still be above whatever is published.
    [int]$Sequence = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot      = Split-Path -Parent $PSScriptRoot
$firmwareDir   = Join-Path $repoRoot 'firmwares'
$notesDir      = Join-Path $repoRoot 'notes'
$catalogPath   = Join-Path $repoRoot 'catalog.xml'
$signaturePath = Join-Path $repoRoot 'catalog.sig'
$aliasPath     = Join-Path $notesDir 'model-aliases.xml'

# --- Sequence: strictly increasing, so a client can refuse to move backwards -----------
# XmlDocument.Load rather than the [xml] cast: the cast's exception message embeds the
# whole document, which buries the actual problem when the file is 56 KB.
# $nextSequence, not $sequence: PowerShell variable names are case-insensitive, so a
# local named $sequence would BE the -Sequence parameter and silently overwrite it.
$nextSequence = 1
if ($Sequence -gt 0) {
    $nextSequence = $Sequence
}
elseif (Test-Path -LiteralPath $catalogPath) {
    $previous = New-Object System.Xml.XmlDocument
    try {
        $previous.Load($catalogPath)
        $nextSequence = [int]$previous.FirmwareCatalog.Sequence + 1
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

$writer = [System.Xml.XmlWriter]::Create($catalogPath, $settings)
try {
    $writer.WriteStartElement('FirmwareCatalog')
    $writer.WriteAttributeString('Schema', '1')
    $writer.WriteAttributeString('Sequence', $nextSequence.ToString())
    $writer.WriteAttributeString('Generated', $generated.ToString('yyyy-MM-ddTHH:mm:ssZ'))
    $writer.WriteAttributeString('ValidUntil', $validUntil.ToString('yyyy-MM-ddTHH:mm:ssZ'))

    foreach ($item in $items) {
        $writer.WriteStartElement('Item')
        $writer.WriteAttributeString('Component', 'Firmwares')
        $writer.WriteAttributeString('Kind', $item.Kind)
        $writer.WriteAttributeString('Model', $item.Model)
        $writer.WriteAttributeString('Version', $item.Version)
        $writer.WriteAttributeString('Target', $item.Target)
        $writer.WriteAttributeString('Source', $item.Source)
        $writer.WriteAttributeString('Size', $item.Size.ToString())
        $writer.WriteAttributeString('Sha256', $item.Sha256)
        $writer.WriteAttributeString('Channel', $Channel)

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

# --- Sign -------------------------------------------------------------------------------
$signed = $false
if (-not [string]::IsNullOrWhiteSpace($PrivateKeyPath)) {
    if (-not (Test-Path -LiteralPath $PrivateKeyPath)) {
        throw "Private key not found: $PrivateKeyPath"
    }

    $rsa = New-Object System.Security.Cryptography.RSACng
    try {
        $rsa.FromXmlString((Get-Content -LiteralPath $PrivateKeyPath -Raw))
        $bytes = [System.IO.File]::ReadAllBytes($catalogPath)
        $sig = $rsa.SignData($bytes,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        [System.IO.File]::WriteAllBytes($signaturePath, $sig)
        $signed = $true
    }
    finally { $rsa.Dispose() }
}
elseif (Test-Path -LiteralPath $signaturePath) {
    # A stale signature is worse than none - it fails verification confusingly.
    Remove-Item -LiteralPath $signaturePath -Force
}

# --- Report -----------------------------------------------------------------------------
Write-Output ""
Write-Output "Catalogue   : $catalogPath"
Write-Output "Sequence    : $nextSequence"
Write-Output "Valid until : $($validUntil.ToString('yyyy-MM-dd'))"
Write-Output "Items       : $($items.Count)"
foreach ($g in ($items | Group-Object Kind | Sort-Object Name)) {
    Write-Output ("                {0,-12} {1}" -f $g.Name, $g.Count)
}
if ($signed) {
    if ($PrivateKeyPath -like '*development*' -or $PrivateKeyPath -like '*dev*') {
        Write-Output "Signed      : yes - WITH A DEVELOPMENT KEY, do not publish"
    }
    else {
        Write-Output "Signed      : yes"
    }
}
else {
    Write-Output "Signed      : NO - unsigned, do not publish"
}

if ($noNotes.Count -gt 0) {
    Write-Output ""
    Write-Warning "$($noNotes.Count) flashable firmware entries have no release notes."
}

if ($unconfirmed.Count -gt 0) {
    Write-Warning "$($unconfirmed.Count) model aliases are unconfirmed - a wrong one shows the notes of a different product."
}
