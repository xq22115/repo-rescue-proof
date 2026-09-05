Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-BraintrustCanonicalValue {
    param([Parameter(ValueFromPipeline = $true)][AllowNull()]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [string] -or
        $Value -is [char] -or
        $Value -is [bool] -or
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64] -or
        $Value -is [single] -or
        $Value -is [double] -or
        $Value -is [decimal] -or
        $Value -is [datetime]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $names = @($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($names, [System.StringComparer]::Ordinal)
        $ordered = [ordered]@{}
        foreach ($name in $names) {
            $ordered[$name] = ConvertTo-BraintrustCanonicalValue $Value[$name]
        }
        return $ordered
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(ConvertTo-BraintrustCanonicalValue $item)
        }
        return @($items)
    }

    $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -match 'Property' })
    if ($properties.Count -gt 0) {
        $names = @($properties | ForEach-Object { [string]$_.Name })
        [Array]::Sort($names, [System.StringComparer]::Ordinal)
        $ordered = [ordered]@{}
        foreach ($name in $names) {
            $property = $Value.PSObject.Properties[$name]
            $ordered[$name] = ConvertTo-BraintrustCanonicalValue $property.Value
        }
        return $ordered
    }

    return $Value
}

function ConvertTo-BraintrustCanonicalJson {
    param(
        [AllowNull()]$Value,
        [int]$Depth = 50
    )

    if ($null -eq $Value) { return 'null' }
    $canonical = ConvertTo-BraintrustCanonicalValue $Value
    return ($canonical | ConvertTo-Json -Depth $Depth -Compress)
}

function Get-BraintrustUtf8Sha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    return (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '')
}
