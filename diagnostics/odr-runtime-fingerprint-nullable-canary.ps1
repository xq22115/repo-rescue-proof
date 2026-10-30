param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NullableIntObservation {
    param([Nullable[int]]$Value)

    if ($null -eq $Value) {
        throw 'The canary requires a non-null Nullable[int] value.'
    }

    $runtimeType = $Value.GetType().FullName
    $directCast = [int]$Value

    $valueMemberReadSucceeded = $false
    $valueMemberResult = $null
    $valueMemberError = $null
    try {
        $valueMemberResult = [int]$Value.Value
        $valueMemberReadSucceeded = $true
    } catch {
        $valueMemberError = $_.Exception.Message
    }

    return [ordered]@{
        runtimeType = $runtimeType
        directCast = $directCast
        valueMemberReadSucceeded = $valueMemberReadSucceeded
        valueMemberResult = $valueMemberResult
        valueMemberError = $valueMemberError
    }
}

$observation = Invoke-NullableIntObservation -Value 0
if ([int]$observation.directCast -ne 0) {
    throw 'Direct cast of a non-null Nullable[int] did not preserve the supplied integer value.'
}

$receipt = [ordered]@{
    schemaVersion = 1
    component = 'diagnostic-powershell-nullable-int-binding'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    psEdition = [string]$PSVersionTable.PSEdition
    psVersion = [string]$PSVersionTable.PSVersion
    clrVersion = if ($PSVersionTable.ContainsKey('CLRVersion')) { [string]$PSVersionTable.CLRVersion } else { $null }
    frameworkDescription = [string][System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
    osDescription = [string][System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    observation = $observation
    acceptance = [ordered]@{
        directCastAfterNullCheckAccepted = $true
        nullableValueMemberAccessAcceptedAsPortableContract = $false
        productionOdrRuntimeFingerprintPatched = $false
        privateRuntimeFingerprintNativeAcceptance = $false
    }
}

$directory = Split-Path -Parent $OutputPath
if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Host ("Nullable[int] observation: edition={0} version={1} runtimeType={2} directCast={3} valueMemberReadSucceeded={4}" -f $receipt.psEdition, $receipt.psVersion, $observation.runtimeType, $observation.directCast, $observation.valueMemberReadSucceeded)
