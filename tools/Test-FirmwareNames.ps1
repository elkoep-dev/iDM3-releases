<#
.SYNOPSIS
    Validates the contents of firmwares/ before it can be published.

.DESCRIPTION
    Every archive must be named exactly as iDM3 expects, because a downloaded file drops
    straight into the tool's Firmwares folder and is matched by name:

        MODEL_MM.mm.pp.zip      version in hexadecimal, e.g. GCH3-31_02.A0.00.zip

    Checks performed:
      - file name matches the pattern iDM3 parses
      - no model/version published twice
      - the archive opens

    Archives are also classified, because Firmwares/ holds three different things:

      Firmware    contains a .if3 or .nf3 image - flashable onto a device
      Definition  contains only unit.xml - a device model, with nothing to flash
      Placeholder an empty archive - a virtual module implemented inside the central unit

    Only Firmware entries may be offered to a technician as an update. The catalogue
    records the kind so iDM3 can tell them apart.

    Exits non-zero on any error, so it can gate a pull request.

.PARAMETER Path
    Firmware directory. Defaults to firmwares/ next to this script's repository root.

.PARAMETER FailOnWarning
    Treat warnings (such as empty placeholder archives) as errors.
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$FailOnWarning,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'firmwares'
}

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Firmware directory not found: $Path"
}

$pattern = '^(?<model>[A-Za-z0-9][A-Za-z0-9\-]*)_(?<version>[0-9A-F]{2}\.[0-9A-F]{2}\.[0-9A-F]{2})\.zip$'

$errors   = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$seen      = @{}
$models    = @{}
$examined  = 0
$inventory = New-Object System.Collections.Generic.List[object]
$kinds     = @{ Firmware = 0; Definition = 0; Placeholder = 0; Unknown = 0 }

foreach ($file in Get-ChildItem -LiteralPath $Path -Filter *.zip -File | Sort-Object Name) {
    $examined++
    $match = [regex]::Match($file.Name, $pattern)

    if (-not $match.Success) {
        $errors.Add("$($file.Name): name does not match MODEL_MM.mm.pp.zip (uppercase hex version)")
        continue
    }

    $model   = $match.Groups['model'].Value
    $version = $match.Groups['version'].Value
    $key     = "$model|$version"

    if ($seen.ContainsKey($key)) {
        $errors.Add("$($file.Name): $model $version is already published as $($seen[$key])")
    }
    else {
        $seen[$key] = $file.Name
    }

    $models[$model] = $true

    # An empty archive is 22 bytes - the end-of-central-directory record and nothing else.
    if ($file.Length -le 22) {
        $kinds['Placeholder'] += 1
        $inventory.Add([pscustomobject]@{ File = $file.Name; Model = $model; Version = $version; Kind = 'Placeholder' })
        continue
    }

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
        try {
            $images = @($zip.Entries | Where-Object { $_.Name -match '\.(if3|nf3)$' })
            $hasUnit = @($zip.Entries | Where-Object { $_.Name -eq 'unit.xml' }).Count -gt 0

            if ($images.Count -gt 0) {
                $kind = 'Firmware'
            }
            elseif ($hasUnit) {
                $kind = 'Definition'
            }
            else {
                $kind = 'Unknown'
                $errors.Add("$($file.Name): contains neither a firmware image nor unit.xml")
            }

            $kinds[$kind] += 1
            $inventory.Add([pscustomobject]@{ File = $file.Name; Model = $model; Version = $version; Kind = $kind })
        }
        finally { $zip.Dispose() }
    }
    catch {
        $errors.Add("$($file.Name): archive could not be opened - $($_.Exception.Message)")
    }
}

Write-Output ""
Write-Output "Firmware directory : $Path"
Write-Output "Archives examined  : $examined"
Write-Output "Distinct models    : $($models.Count)"
Write-Output ""
Write-Output "  Firmware (flashable) : $($kinds['Firmware'])"
Write-Output "  Definition only      : $($kinds['Definition'])"
Write-Output "  Placeholder (empty)  : $($kinds['Placeholder'])"
Write-Output ""

if ($PassThru) { $inventory }


foreach ($w in $warnings) { Write-Warning $w }
foreach ($e in $errors)   { Write-Output "ERROR: $e" }

if ($errors.Count -gt 0) {
    Write-Output ""
    Write-Output "FAILED - $($errors.Count) error(s), $($warnings.Count) warning(s)."
    exit 1
}

if ($FailOnWarning -and $warnings.Count -gt 0) {
    Write-Output ""
    Write-Output "FAILED - $($warnings.Count) warning(s), and -FailOnWarning was set."
    exit 1
}

Write-Output "PASSED - $($warnings.Count) warning(s)."
exit 0
