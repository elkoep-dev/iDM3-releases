<#
.SYNOPSIS
    Verifies catalog.xml the way iDM3 will verify it.

.DESCRIPTION
    Checks, in the order the client performs them:

      1. Every Item's archive exists and its SHA-256 matches the catalogue.
      2. Any MinAppVersion is a version iDM3 can compare.
      3. No Item carries executable content.
      4. ValidUntil has not passed.
      5. Sequence has not gone backwards relative to -PreviousSequence.

    Run it before publishing, and in CI on every pull request.

    The catalogue is not signed, so this does not establish who produced it - only that
    it is internally consistent and that every archive it lists is intact. Authenticity
    rests on HTTPS to the repository host and on who can push to it. See README.md.

.PARAMETER PreviousSequence
    The Sequence of the currently published catalogue. Supplying it catches a rollback,
    where an older catalogue is republished to steer clients onto a withdrawn firmware.
#>
[CmdletBinding()]
param(
    [int]$PreviousSequence = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Files iDM3 would load or launch rather than read. The catalogue is unsigned, so an
# executable delivered through it turns a stolen repository token into code execution on
# every engineer's machine. Anything on this list belongs in the installer instead.
$executableExtensions = @('.exe', '.dll', '.com', '.bat', '.cmd', '.ps1', '.msi', '.scr', '.vbs', '.js')

$repoRoot      = Split-Path -Parent $PSScriptRoot
$catalogPath   = Join-Path $repoRoot 'catalog.xml'

if (-not (Test-Path -LiteralPath $catalogPath)) {
    throw "catalog.xml not found. Run Build-Catalog.ps1 first."
}

$errors   = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

# A corrupted catalogue is exactly what this tool exists to catch, so report it rather
# than letting the parser throw a wall of the malformed document. XmlDocument.Load is
# used instead of the [xml] cast because the cast's exception message embeds the entire
# file, which is useless output when the file is 56 KB.
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

# Anything on disk the catalogue does not list is unpublished, and clients will never
# offer it - worth reporting so it is not mistaken for a release.
$listed = @{}
foreach ($item in @($catalog.FirmwareCatalog.Item)) {
    if ($null -ne $item) { $listed[[System.IO.Path]::GetFileName($item.Source)] = $true }
}
foreach ($onDisk in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'firmwares') -Filter *.zip -File -ErrorAction SilentlyContinue) {
    if (-not $listed.ContainsKey($onDisk.Name)) {
        $warnings.Add("$($onDisk.Name) is in firmwares/ but not in the catalogue - it will not be offered to anyone.")
    }
}

# An unlisted content file is an error rather than a warning: it was published
# deliberately and does nothing, which is worse than not publishing it at all. This is
# the check that would have caught .config-overlay being skipped because a leading dot
# makes a directory hidden on Linux. -Force for the same reason.
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
# An unparseable MinAppVersion is worse than none: iDM3 cannot compare it, so it either
# skips content it should apply or applies content it should not.
foreach ($item in @($catalog.FirmwareCatalog.Item)) {
    if ($null -eq $item) { continue }

    $floor = $item.GetAttribute('MinAppVersion')
    if ([string]::IsNullOrWhiteSpace($floor)) {
        # Firmware must reach installations older than the release that published it,
        # so a missing floor is correct there and merely unremarkable elsewhere.
        continue
    }

    $parsed = $null
    if (-not [Version]::TryParse($floor, [ref]$parsed)) {
        $errors.Add("$($item.Source): MinAppVersion '$floor' is not a version iDM3 can compare.")
    }
    elseif ($item.Component -eq 'Firmwares') {
        $warnings.Add("$($item.Source): firmware carries MinAppVersion $floor, so installations older than that will not be offered it. Intended?")
    }
}

# --- 3. Executable content ------------------------------------------------------------------
# The catalogue carries content only: files that are read, never executed. This is the one
# check that cannot be recovered after the fact - by the time a bad archive has been fetched
# and unpacked, the machine has already run it.
foreach ($item in @($catalog.FirmwareCatalog.Item)) {
    if ($null -eq $item) { continue }

    # Target and Source normally share an extension; reported once either way, because two
    # lines about one file reads as two problems.
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

    # Content under content/ is delivered as the file itself, so its own extension - checked
    # above - is the whole story. Only archives have entries to look inside.
    if ([System.IO.Path]::GetExtension($full).ToLowerInvariant() -ne '.zip') { continue }

    # An archive is unpacked into the installation, so its entries matter as much as its name.
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
Write-Output "Signature        : none - the catalogue is unsigned by design, see README.md"
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
