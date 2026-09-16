<#
.SYNOPSIS
    Portable RSA helpers for the .NET XML key format.

.DESCRIPTION
    The keys are stored in the XML format .NET Framework uses, because iDM3 runs on
    .NET Framework 4.8 and reads them with RSA.FromXmlString. That is convenient on
    Windows and unavailable elsewhere: RSACng is a Windows-only CNG wrapper, and
    ToXmlString / FromXmlString are not implemented on .NET outside Windows.

    These helpers read and write that exact format by hand - base64 fields into and out
    of RSAParameters - using only RSA.Create(), which every platform and runtime
    supports. The files produced are byte-identical to what RSACng produced, so the
    Windows client is unaffected and existing keys and signatures keep working.

    Dot-source this from the other scripts:
        . (Join-Path $PSScriptRoot 'RsaXml.ps1')
#>

function ConvertFrom-RsaXml {
    <#
    .SYNOPSIS
        Builds an RSA object from a .NET XML key. Private fields are optional.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Xml)

    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    $document.LoadXml($Xml)

    $root = $document.DocumentElement
    if ($null -eq $root -or $root.Name -ne 'RSAKeyValue') {
        throw "Not an RSA key: the root element is <$($root.Name)>, expected <RSAKeyValue>."
    }

    function Get-Field {
        param([string]$Name)
        $node = $root.SelectSingleNode($Name)
        if ($null -eq $node -or [string]::IsNullOrWhiteSpace($node.InnerText)) { return $null }
        return [Convert]::FromBase64String($node.InnerText.Trim())
    }

    $parameters = New-Object System.Security.Cryptography.RSAParameters
    $parameters.Modulus  = Get-Field 'Modulus'
    $parameters.Exponent = Get-Field 'Exponent'

    if ($null -eq $parameters.Modulus -or $null -eq $parameters.Exponent) {
        throw "The RSA key is missing Modulus or Exponent."
    }

    # Present only in a private key. All of them must be there, or none.
    $d = Get-Field 'D'
    if ($null -ne $d) {
        $parameters.D        = $d
        $parameters.P        = Get-Field 'P'
        $parameters.Q        = Get-Field 'Q'
        $parameters.DP       = Get-Field 'DP'
        $parameters.DQ       = Get-Field 'DQ'
        $parameters.InverseQ = Get-Field 'InverseQ'

        foreach ($name in @('P', 'Q', 'DP', 'DQ', 'InverseQ')) {
            if ($null -eq $parameters.$name) {
                throw "The private key is incomplete: <$name> is missing."
            }
        }
    }

    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportParameters($parameters)
    return $rsa
}

function ConvertTo-RsaXml {
    <#
    .SYNOPSIS
        Serialises an RSA object to the .NET XML key format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Security.Cryptography.RSA]$Rsa,
        [switch]$IncludePrivateParameters
    )

    $p = $Rsa.ExportParameters($IncludePrivateParameters.IsPresent)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('<RSAKeyValue>')
    [void]$builder.Append('<Modulus>').Append([Convert]::ToBase64String($p.Modulus)).Append('</Modulus>')
    [void]$builder.Append('<Exponent>').Append([Convert]::ToBase64String($p.Exponent)).Append('</Exponent>')

    if ($IncludePrivateParameters) {
        # Field order matches .NET's own output, so the files are interchangeable.
        [void]$builder.Append('<P>').Append([Convert]::ToBase64String($p.P)).Append('</P>')
        [void]$builder.Append('<Q>').Append([Convert]::ToBase64String($p.Q)).Append('</Q>')
        [void]$builder.Append('<DP>').Append([Convert]::ToBase64String($p.DP)).Append('</DP>')
        [void]$builder.Append('<DQ>').Append([Convert]::ToBase64String($p.DQ)).Append('</DQ>')
        [void]$builder.Append('<InverseQ>').Append([Convert]::ToBase64String($p.InverseQ)).Append('</InverseQ>')
        [void]$builder.Append('<D>').Append([Convert]::ToBase64String($p.D)).Append('</D>')
    }

    [void]$builder.Append('</RSAKeyValue>')
    return $builder.ToString()
}

function New-RsaKey {
    [CmdletBinding()]
    param([int]$KeySize = 3072)
    return [System.Security.Cryptography.RSA]::Create($KeySize)
}
