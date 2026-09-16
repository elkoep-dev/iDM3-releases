<#
.SYNOPSIS
    Converts the hand-maintained firmware history text files into structured release notes.

.DESCRIPTION
    ELKO EP has maintained a per-device history file for years, in the iDM3 installer under
    Advance\Documentation\Firmware history. Those files are the release notes - they just
    are not machine-readable, so iDM3 cannot show them and the website cannot render them.

    This converts each one into notes\<MODEL>.xml, which Build-Catalog.ps1 folds into the
    signed catalogue. It is re-runnable: run it again after editing a source file and the
    output is regenerated.

    Source format, consistent across all 72 files:

        /********************************/      <- banner, ignored
        Version 02.9E.00                        <- entry
        News:                                   <- optional label, dropped
        - support for hardware without sensor   <- bullet
          continuation of the previous bullet   <- appended to it
        ------------------------------          <- entry separator

.PARAMETER HistoryPath
    Folder holding the "<MODEL> - Firmware history.txt" files.

.PARAMETER Language
    Language tag recorded on the notes. The existing files are English.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HistoryPath,

    [string]$Language = 'en',

    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot 'notes'
}

if (-not (Test-Path -LiteralPath $HistoryPath)) {
    throw "History folder not found: $HistoryPath"
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$versionPattern = '^\s*Version\s+(?<version>[0-9A-Fa-f]{2}\.[0-9A-Fa-f]{2}\.[0-9A-Fa-f]{2})\s*$'
$separator      = '^\s*-{5,}\s*$'
$labelPattern   = '^\s*(News|New|Bugs|Fixes|Fixed)\s*:\s*$'
$bannerPattern  = '^\s*(/\*|\*)'

$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
$totalFiles = 0
$totalNotes = 0
$skipped    = New-Object System.Collections.Generic.List[string]

foreach ($file in Get-ChildItem -LiteralPath $HistoryPath -Filter '* - Firmware history.txt' -File | Sort-Object Name) {

    $model = $file.BaseName -replace ' - Firmware history$', ''
    if ([string]::IsNullOrWhiteSpace($model)) {
        $skipped.Add("$($file.Name): could not derive a model name"); continue
    }

    # These files predate UTF-8 here; read as the system codepage so accented
    # characters survive instead of becoming replacement characters.
    $lines = [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::Default)

    $entries = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($raw in $lines) {
        $line = $raw.TrimEnd()

        if ($line -match $bannerPattern) { continue }
        if ($line -match $separator)     { continue }
        if ($line -match $labelPattern)  { continue }

        $versionMatch = [regex]::Match($line, $versionPattern)
        if ($versionMatch.Success) {
            $current = [pscustomobject]@{
                Version = $versionMatch.Groups['version'].Value.ToUpperInvariant()
                Bullets = New-Object System.Collections.Generic.List[string]
            }
            $entries.Add($current)
            continue
        }

        if ($null -eq $current) { continue }          # preamble before the first version
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('-')) {
            $text = $trimmed.Substring(1).Trim()
            if ($text.Length -gt 0) { $current.Bullets.Add($text) }
        }
        elseif ($current.Bullets.Count -gt 0) {
            # A wrapped continuation of the bullet above it.
            $last = $current.Bullets.Count - 1
            $current.Bullets[$last] = "$($current.Bullets[$last]) $trimmed"
        }
    }

    if ($entries.Count -eq 0) {
        $skipped.Add("$($file.Name): no version entries found"); continue
    }

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent             = $true
    $settings.IndentChars        = '  '
    $settings.Encoding           = $utf8NoBom
    $settings.NewLineChars       = "`n"
    $settings.OmitXmlDeclaration = $false

    $target = Join-Path $OutputPath "$model.xml"
    $writer = [System.Xml.XmlWriter]::Create($target, $settings)
    try {
        $writer.WriteStartElement('ReleaseNotes')
        $writer.WriteAttributeString('Model', $model)
        $writer.WriteAttributeString('Source', $file.Name)

        foreach ($entry in $entries) {
            $writer.WriteStartElement('Release')
            $writer.WriteAttributeString('Version', $entry.Version)
            foreach ($bullet in $entry.Bullets) {
                $writer.WriteStartElement('Note')
                $writer.WriteAttributeString('Lang', $Language)
                $writer.WriteString($bullet)
                $writer.WriteEndElement()
            }
            $writer.WriteEndElement()
            $totalNotes++
        }

        $writer.WriteEndElement()
    }
    finally { $writer.Close() }

    $totalFiles++
}

Write-Output ""
Write-Output "Source   : $HistoryPath"
Write-Output "Output   : $OutputPath"
Write-Output "Models   : $totalFiles"
Write-Output "Releases : $totalNotes"

if ($skipped.Count -gt 0) {
    Write-Output ""
    foreach ($s in $skipped) { Write-Warning $s }
}
