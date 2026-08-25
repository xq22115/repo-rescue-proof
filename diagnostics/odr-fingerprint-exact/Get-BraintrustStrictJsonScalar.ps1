Set-StrictMode -Version Latest

function Get-BraintrustRequiredJsonBoolean {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Alias('FieldName')][string]$FieldPath
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "Missing required JSON boolean '$FieldPath'."
    }
    if ($property.Value -isnot [bool]) {
        $actualType = if ($null -eq $property.Value) { 'null' } else { $property.Value.GetType().FullName }
        throw "JSON field '$FieldPath' must be a boolean; actual type was '$actualType'."
    }
    return [bool]$property.Value
}
