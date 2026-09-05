$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$cmdlets = [ordered]@{
    'Set-Variable'    = 'Microsoft.PowerShell.Utility'
    'New-Variable'    = 'Microsoft.PowerShell.Utility'
    'Clear-Variable'  = 'Microsoft.PowerShell.Utility'
    'Remove-Variable' = 'Microsoft.PowerShell.Utility'
    'Set-Item'        = 'Microsoft.PowerShell.Management'
    'Clear-Item'      = 'Microsoft.PowerShell.Management'
    'Remove-Item'     = 'Microsoft.PowerShell.Management'
}

$cmdletObservations = @()
foreach ($entry in $cmdlets.GetEnumerator()) {
    $name = [string]$entry.Key
    $module = [string]$entry.Value
    $qualifiedName = "$module\$name"

    $observation = & {
        param($Name, $Module, $QualifiedName)
        $functionPath = "Function:$Name"
        try {
            Microsoft.PowerShell.Management\Set-Item -LiteralPath $functionPath -Value { 'braintrust-shadow-marker' } -Force
            $unqualified = Get-Command -Name $Name -ErrorAction Stop
            $qualified = Get-Command -Name $QualifiedName -ErrorAction Stop
            [pscustomobject]@{
                Name = $Name
                UnqualifiedType = [string]$unqualified.CommandType
                QualifiedType = [string]$qualified.CommandType
                QualifiedModule = [string]$qualified.ModuleName
            }
        }
        finally {
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $functionPath -Force -ErrorAction SilentlyContinue
        }
    } $name $module $qualifiedName

    if ($observation.UnqualifiedType -ne 'Function') {
        throw "CMDLET_FUNCTION_SHADOW_NOT_OBSERVED name=$name type=$($observation.UnqualifiedType)"
    }
    if ($observation.QualifiedType -ne 'Cmdlet' -or $observation.QualifiedModule -ne $module) {
        throw "MODULE_QUALIFIED_CMDLET_RESOLUTION_MISMATCH name=$name expectedModule=$module actualType=$($observation.QualifiedType) actualModule=$($observation.QualifiedModule)"
    }
    $cmdletObservations += $observation
}

$aliases = [ordered]@{
    set = 'Set-Variable'
    sv  = 'Set-Variable'
    nv  = 'New-Variable'
    clv = 'Clear-Variable'
    rv  = 'Remove-Variable'
    si  = 'Set-Item'
    cli = 'Clear-Item'
    ri  = 'Remove-Item'
}

$aliasObservations = @()
foreach ($entry in $aliases.GetEnumerator()) {
    $name = [string]$entry.Key
    $expectedDefinition = [string]$entry.Value
    $observation = & {
        param($Name, $ExpectedDefinition)
        $functionPath = "Function:$Name"
        try {
            Microsoft.PowerShell.Management\Set-Item -LiteralPath $functionPath -Value { 'braintrust-function-marker' } -Force
            $resolved = Get-Command -Name $Name -ErrorAction Stop
            [pscustomobject]@{
                Name = $Name
                ResolvedType = [string]$resolved.CommandType
                Definition = [string]$resolved.Definition
            }
        }
        finally {
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $functionPath -Force -ErrorAction SilentlyContinue
        }
    } $name $expectedDefinition

    if ($observation.ResolvedType -ne 'Alias') {
        throw "ALIAS_DID_NOT_PRECEDE_SAME_NAME_FUNCTION name=$name actualType=$($observation.ResolvedType)"
    }
    if ($observation.Definition -ne $expectedDefinition) {
        throw "ALIAS_DEFINITION_MISMATCH name=$name expected=$expectedDefinition actual=$($observation.Definition)"
    }
    $aliasObservations += $observation
}

$result = [ordered]@{
    component = 'powershell-variable-command-identity-canary'
    schemaVersion = 1
    psEdition = [string]$PSVersionTable.PSEdition
    psVersion = [string]$PSVersionTable.PSVersion
    osVersion = [string][Environment]::OSVersion.Version
    unqualifiedCanonicalCmdletsCanBeFunctionShadowedObserved = $true
    moduleQualifiedCanonicalCmdletsBypassFunctionShadowObserved = $true
    builtInAliasesPrecedeSameNameFunctionsObserved = $true
    aliasSpellingsAcceptedAsImmutableCmdletIdentity = $false
    priorSessionAliasStateKnownToStaticAnalyzer = $false
    commandObservations = $cmdletObservations
    aliasObservations = $aliasObservations
}
$result | ConvertTo-Json -Depth 6 -Compress
Write-Host 'POWERSHELL_VARIABLE_COMMAND_IDENTITY_CANARY_PASS'
