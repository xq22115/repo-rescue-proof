Set-StrictMode -Version Latest

function Get-BraintrustJsonProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property
}

function Test-BraintrustJsonObjectValue {
    param([object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $true }
    return ($Value -is [pscustomobject])
}

function Assert-BraintrustJsonObjectValue {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    if (-not (Test-BraintrustJsonObjectValue -Value $Value)) {
        $actualType = if ($null -eq $Value) { 'null' } else { $Value.GetType().FullName }
        throw "JSON field '$FieldPath' must be an object; actual type was '$actualType'. Scalar/array coercion is forbidden."
    }

    return $Value
}

function Get-BraintrustRequiredJsonObject {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    $property = Get-BraintrustJsonProperty -Object $Object -Name $Name
    if ($null -eq $property) {
        throw "Missing required JSON object '$FieldPath'."
    }

    return Assert-BraintrustJsonObjectValue -Value $property.Value -FieldPath $FieldPath
}

function Get-BraintrustOptionalJsonObject {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    $property = Get-BraintrustJsonProperty -Object $Object -Name $Name
    if ($null -eq $property) { return $null }
    return Assert-BraintrustJsonObjectValue -Value $property.Value -FieldPath $FieldPath
}

function Test-BraintrustJsonArrayValue {
    param([object]$Value)

    if ($null -eq $Value) { return $false }
    return ($Value -is [System.Array])
}

function Assert-BraintrustJsonArrayValue {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    if (-not (Test-BraintrustJsonArrayValue -Value $Value)) {
        $actualType = if ($null -eq $Value) { 'null' } else { $Value.GetType().FullName }
        throw "JSON field '$FieldPath' must be an array; actual type was '$actualType'. Scalar/object coercion is forbidden."
    }

    return @($Value)
}

function Get-BraintrustRequiredJsonArray {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    $property = Get-BraintrustJsonProperty -Object $Object -Name $Name
    if ($null -eq $property) {
        throw "Missing required JSON array '$FieldPath'."
    }

    return @(Assert-BraintrustJsonArrayValue -Value $property.Value -FieldPath $FieldPath)
}

function Get-BraintrustOptionalJsonArray {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    $property = Get-BraintrustJsonProperty -Object $Object -Name $Name
    if ($null -eq $property) { return $null }
    return @(Assert-BraintrustJsonArrayValue -Value $property.Value -FieldPath $FieldPath)
}

function Get-BraintrustRequiredJsonBoolean {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    $property = Get-BraintrustJsonProperty -Object $Object -Name $Name
    if ($null -eq $property) {
        throw "Missing required JSON boolean '$FieldPath'."
    }

    if ($property.Value -isnot [bool]) {
        $actualType = if ($null -eq $property.Value) { 'null' } else { $property.Value.GetType().FullName }
        throw "JSON field '$FieldPath' must be a boolean; actual type was '$actualType'. String/numeric coercion is forbidden."
    }

    return [bool]$property.Value
}

function Get-BraintrustOptionalJsonBoolean {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath,
        [bool]$DefaultValue = $false
    )

    $property = Get-BraintrustJsonProperty -Object $Object -Name $Name
    if ($null -eq $property) { return $DefaultValue }

    if ($property.Value -isnot [bool]) {
        $actualType = if ($null -eq $property.Value) { 'null' } else { $property.Value.GetType().FullName }
        throw "JSON field '$FieldPath' must be a boolean when present; actual type was '$actualType'. String/numeric coercion is forbidden."
    }

    return [bool]$property.Value
}

function Get-BraintrustRequiredJsonString {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath,
        [switch]$AllowEmpty
    )

    $property = Get-BraintrustJsonProperty -Object $Object -Name $Name
    if ($null -eq $property) {
        throw "Missing required JSON string '$FieldPath'."
    }

    if ($property.Value -isnot [string]) {
        $actualType = if ($null -eq $property.Value) { 'null' } else { $property.Value.GetType().FullName }
        throw "JSON field '$FieldPath' must be a string; actual type was '$actualType'. Numeric/boolean/object/array coercion is forbidden."
    }

    $value = [string]$property.Value
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($value)) {
        throw "JSON field '$FieldPath' must be a non-empty string."
    }

    return $value
}

function Get-BraintrustRequiredJsonTimestampString {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    $property = Get-BraintrustJsonProperty -Object $Object -Name $Name
    if ($null -eq $property) {
        throw "Missing required JSON timestamp string '$FieldPath'."
    }

    if ($property.Value -is [string]) {
        $value = [string]$property.Value
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "JSON timestamp field '$FieldPath' must be a non-empty string."
        }
        try {
            [void][DateTimeOffset]::Parse($value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        } catch {
            throw "JSON timestamp field '$FieldPath' must be a valid ISO-8601 string."
        }
        return $value
    }

    if ($property.Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$property.Value).ToUniversalTime().ToString('o')
    }
    if ($property.Value -is [DateTime]) {
        $dt = [DateTime]$property.Value
        if ($dt.Kind -eq [DateTimeKind]::Unspecified) {
            $dt = [DateTime]::SpecifyKind($dt, [DateTimeKind]::Local)
        }
        return $dt.ToUniversalTime().ToString('o')
    }

    $actualType = if ($null -eq $property.Value) { 'null' } else { $property.Value.GetType().FullName }
    throw "JSON field '$FieldPath' must originate from an ISO-8601 JSON string; actual type was '$actualType'. Numeric/boolean/object/array coercion is forbidden."
}

function Get-BraintrustOptionalJsonString {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath,
        [switch]$AllowEmpty
    )

    $property = Get-BraintrustJsonProperty -Object $Object -Name $Name
    if ($null -eq $property) { return $null }

    if ($property.Value -isnot [string]) {
        $actualType = if ($null -eq $property.Value) { 'null' } else { $property.Value.GetType().FullName }
        throw "JSON field '$FieldPath' must be a string when present; actual type was '$actualType'. Numeric/boolean/object/array coercion is forbidden."
    }

    $value = [string]$property.Value
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($value)) {
        throw "JSON field '$FieldPath' must be a non-empty string when present."
    }

    return $value
}

function Test-BraintrustJsonNumericClrType {
    param([object]$Value)

    if ($null -eq $Value) { return $false }
    return (
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
        $Value -is [decimal]
    )
}

function ConvertTo-BraintrustFiniteDecimal {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$FieldPath
    )

    if (-not (Test-BraintrustJsonNumericClrType -Value $Value)) {
        $actualType = if ($null -eq $Value) { 'null' } else { $Value.GetType().FullName }
        throw "JSON field '$FieldPath' must be a JSON number; actual type was '$actualType'. String/boolean/object/array coercion is forbidden."
    }

    if ($Value -is [double]) {
        if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) {
            throw "JSON field '$FieldPath' must be finite."
        }
    } elseif ($Value -is [single]) {
        if ([single]::IsNaN($Value) -or [single]::IsInfinity($Value)) {
            throw "JSON field '$FieldPath' must be finite."
        }
    }

    try {
        return [decimal]$Value
    } catch {
        throw "JSON field '$FieldPath' is outside the System.Decimal range supported by this verifier."
    }
}

function Get-BraintrustRequiredJsonFiniteNumber {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    $property = Get-BraintrustJsonProperty -Object $Object -Name $Name
    if ($null -eq $property) {
        throw "Missing required JSON number '$FieldPath'."
    }

    return ConvertTo-BraintrustFiniteDecimal -Value $property.Value -FieldPath $FieldPath
}

function Get-BraintrustOptionalJsonFiniteNumber {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    $property = Get-BraintrustJsonProperty -Object $Object -Name $Name
    if ($null -eq $property) { return $null }
    return ConvertTo-BraintrustFiniteDecimal -Value $property.Value -FieldPath $FieldPath
}

function Get-BraintrustRequiredJsonInteger {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    $value = Get-BraintrustRequiredJsonFiniteNumber -Object $Object -Name $Name -FieldPath $FieldPath
    if ([decimal]::Truncate($value) -ne $value) {
        throw "JSON field '$FieldPath' must be an integer."
    }
    return $value
}

function Get-BraintrustOptionalJsonInteger {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    $property = Get-BraintrustJsonProperty -Object $Object -Name $Name
    if ($null -eq $property) { return $null }
    $value = ConvertTo-BraintrustFiniteDecimal -Value $property.Value -FieldPath $FieldPath
    if ([decimal]::Truncate($value) -ne $value) {
        throw "JSON field '$FieldPath' must be an integer when present."
    }
    return $value
}
