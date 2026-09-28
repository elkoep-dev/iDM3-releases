<#
.SYNOPSIS
    Checks that catalog.xml matches the files in the repository.

.DESCRIPTION
      1. Every item's file exists and its SHA-256 matches.
      2. MinAppVersion values are valid versions.
      3. No item contains executables.
      4. ValidUntil has not passed.
      5. Sequence is not lower than -PreviousSequence.

    The signature is checked by the release workflow in iDM-3.5.xx.

.PARAMETER PreviousSequence
    Sequence of the currently published catalogue.
#>
[CmdletBinding()]
param(
    [int]$PreviousSequence = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Executables are only delivered in the installer, never through the catalogue.
$executableExtensions = @('.exe', '.dll', '.com', '.bat', '.cmd', '.ps1', '.msi', '.scr', '.vbs', '.js')

$repoRoot      = Split-Path -Parent $PSScriptRoot
$catalogPath   = Join-Path $repoRoot 'catalog.xml'

if (-not (Test-Path -LiteralPath $catalogPath)) {
    throw "catalog.xml not found."
}

$errors   = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

# XmlDocument.Load rather than [xml], whose error message contains the whole file.
$catalog = New-Object System.Xml.XmlDocument
try {
    $catalog.Load($catalogPath)
}
catch {
    $reason = $_.Exception.Message
    if ($reason.Length -gt 300) { $reason = $reason.Substring(0, 300) + '...' }

    Write-Output ""
    Write-Output "Catalogue : $catalogPath"
    Write-Output ""
    Write-Output "ERROR: catalog.xml is not well-formed XML - $reason"
    Write-Output ""
    Write-Output "FAILED - the catalogue is corrupt. Do not publish it."
    exit 1
}

if ($null -eq $catalog.FirmwareCatalog) {
    Write-Output ""
    Write-Output "ERROR: the root element is not <FirmwareCatalog>."
    Write-Output "FAILED - the catalogue is not a catalogue."
    exit 1
}

$sequence = [int]$catalog.FirmwareCatalog.Sequence

# --- 1. Artifact digests ------------------------------------------------------------------
$checked = 0
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    foreach ($item in @($catalog.FirmwareCatalog.Item)) {
        if ($null -eq $item) { continue }

        $source = $item.Source -replace '/', [System.IO.Path]::DirectorySeparatorChar
        $full   = Join-Path $repoRoot $source

        if (-not (Test-Path -LiteralPath $full)) {
            $errors.Add("$($item.Source): listed in the catalogue but not present in the repository")
            continue
        }

        $file = Get-Item -LiteralPath $full
        if ($file.Length -ne [long]$item.Size) {
            $errors.Add("$($item.Source): size is $($file.Length), catalogue says $($item.Size)")
        }

        $stream = [System.IO.File]::OpenRead($full)
        try {
            $digest = -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
        }
        finally { $stream.Dispose() }

        if ($digest -ne $item.Sha256) {
            $errors.Add("$($item.Source): SHA-256 does not match the catalogue")
        }
        $checked++
    }
}
finally { $sha.Dispose() }

# Files not listed in the catalogue are never offered.
$listed = @{}
foreach ($item in @($catalog.FirmwareCatalog.Item)) {
    if ($null -ne $item) { $listed[[System.IO.Path]::GetFileName($item.Source)] = $true }
}
foreach ($onDisk in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'firmwares') -Filter *.zip -File -ErrorAction SilentlyContinue) {
    if (-not $listed.ContainsKey($onDisk.Name)) {
        $warnings.Add("$($onDisk.Name) is in firmwares/ but not in the catalogue - it will not be offered to anyone.")
    }
}

# An unlisted file in content/ is an error. -Force includes hidden folders.
$contentDir = Join-Path $repoRoot 'content'
if (Test-Path -LiteralPath $contentDir) {
    $contentRoot = (Resolve-Path -LiteralPath $contentDir).Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar)

    $listedSources = @{}
    foreach ($item in @($catalog.FirmwareCatalog.Item)) {
        if ($null -ne $item) { $listedSources[$item.Source] = $true }
    }

    foreach ($onDisk in Get-ChildItem -LiteralPath $contentDir -File -Recurse -Force) {
        $relative = $onDisk.FullName.Substring($contentRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
        $source   = 'content/' + ($relative -replace '\\', '/')

        if (-not $listedSources.ContainsKey($source)) {
            $errors.Add("$source is in content/ but not in the catalogue - it was published and will never be fetched.")
        }
    }
}

# --- 2. Version floors ------------------------------------------------------------------------
foreach ($item in @($catalog.FirmwareCatalog.Item)) {
    if ($null -eq $item) { continue }

    $floor = $item.GetAttribute('MinAppVersion')
    if ([string]::IsNullOrWhiteSpace($floor)) {
        continue
    }

    $parsed = $null
    if (-not [Version]::TryParse($floor, [ref]$parsed)) {
        $errors.Add("$($item.Source): MinAppVersion '$floor' is not a version iDM3 can compare.")
    }
}

# --- 3. Executable content ------------------------------------------------------------------
foreach ($item in @($catalog.FirmwareCatalog.Item)) {
    if ($null -eq $item) { continue }

    # Reported once even if both Target and Source match.
    foreach ($path in @($item.Target, $item.Source)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        if ($executableExtensions -contains $extension) {
            $errors.Add("$($item.Source): the catalogue may not carry executable content ($extension). It belongs in the installer.")
            break
        }
    }

    $source = $item.Source -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $full   = Join-Path $repoRoot $source
    if (-not (Test-Path -LiteralPath $full)) { continue }

    # Only archives have entries to check.
    if ([System.IO.Path]::GetExtension($full).ToLowerInvariant() -ne '.zip') { continue }

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($full)
        foreach ($entry in $archive.Entries) {
            $extension = [System.IO.Path]::GetExtension($entry.FullName).ToLowerInvariant()
            if ($executableExtensions -contains $extension) {
                $errors.Add("$($item.Source): contains executable content ($($entry.FullName)). It belongs in the installer.")
            }
        }
    }
    catch {
        $errors.Add("$($item.Source): could not be opened as a zip archive: $($_.Exception.Message)")
    }
    finally { if ($null -ne $archive) { $archive.Dispose() } }
}

# --- 4. Freshness -------------------------------------------------------------------------
$validUntil = [DateTime]::MinValue
if ([DateTime]::TryParse($catalog.FirmwareCatalog.ValidUntil, [ref]$validUntil)) {
    if ($validUntil.ToUniversalTime() -lt [DateTime]::UtcNow) {
        $errors.Add("The catalogue expired on $($validUntil.ToString('yyyy-MM-dd')). Rebuild it.")
    }
}
else {
    $errors.Add("ValidUntil is missing or unparseable.")
}

# --- 5. Rollback ---------------------------------------------------------------------------
if ($PreviousSequence -gt 0 -and $sequence -le $PreviousSequence) {
    $errors.Add("Sequence $sequence is not greater than the published $PreviousSequence. Clients reject a catalogue that moves backwards.")
}

# --- Report ---------------------------------------------------------------------------------
Write-Output ""
Write-Output "Catalogue        : $catalogPath"
Write-Output "Sequence         : $sequence"
Write-Output "Valid until      : $($catalog.FirmwareCatalog.ValidUntil)"
Write-Output "Items verified   : $checked"
Write-Output "Signature        : $(if (Test-Path -LiteralPath (Join-Path $repoRoot 'catalog.bundle')) { 'catalog.bundle present' } else { 'missing' })"
Write-Output ""

foreach ($w in $warnings) { Write-Warning $w }
foreach ($e in $errors) { Write-Output "ERROR: $e" }

if ($errors.Count -gt 0) {
    Write-Output ""
    Write-Output "FAILED - $($errors.Count) error(s), $($warnings.Count) warning(s)."
    exit 1
}

Write-Output "PASSED - $($warnings.Count) warning(s)."
exit 0
