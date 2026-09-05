$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$expectedAliases = [ordered]@{
    cd    = 'Set-Location'
    chdir = 'Set-Location'
    sl    = 'Set-Location'
    pushd = 'Push-Location'
}

$observations = @()

foreach ($entry in $expectedAliases.GetEnumerator()) {
    $alias = Get-Alias -Name $entry.Key -ErrorAction Stop
    if ($alias.Definition -ne $entry.Value) {
        throw "LOCATION_ALIAS_DEFAULT_MISMATCH name=$($entry.Key) expected=$($entry.Value) actual=$($alias.Definition)"
    }
    $resolved = Get-Command -Name $entry.Key -ErrorAction Stop
    if ($resolved.CommandType -ne 'Alias' -or $resolved.Definition -ne $entry.Value) {
        throw "LOCATION_ALIAS_DEFAULT_RESOLUTION_MISMATCH name=$($entry.Key) type=$($resolved.CommandType) definition=$($resolved.Definition)"
    }

    $originalDefinition = [string]$alias.Definition
    $originalOptions = $alias.Options

    $functionPrecedence = & {
        Set-Item -Path ("Function:{0}" -f $entry.Key) -Value { 'function-shadow-probe' }
        $resolvedHere = Get-Command -Name $entry.Key -ErrorAction Stop
        [pscustomobject]@{
            Type = [string]$resolvedHere.CommandType
            Definition = [string]$resolvedHere.Definition
        }
    }
    if ($functionPrecedence.Type -ne 'Alias' -or $functionPrecedence.Definition -ne $entry.Value) {
        throw "LOCATION_ALIAS_PRECEDENCE_MISMATCH name=$($entry.Key) type=$($functionPrecedence.Type) definition=$($functionPrecedence.Definition)"
    }

    $setAliasRebindObserved = $false
    try {
        Set-Alias -Name $entry.Key -Value Write-Output -Scope Local -Option $originalOptions -Force
        $changed = Get-Alias -Name $entry.Key -ErrorAction Stop
        if ($changed.Definition -ne 'Write-Output') {
            throw "LOCATION_ALIAS_SET_ALIAS_REBIND_FAILED name=$($entry.Key) actual=$($changed.Definition)"
        }
        $setAliasRebindObserved = $true
    }
    finally {
        Set-Alias -Name $entry.Key -Value $originalDefinition -Scope Local -Option $originalOptions -Force
    }

    $aliasProviderRebindObserved = $false
    try {
        Set-Item -Path ("Alias:{0}" -f $entry.Key) -Value Write-Output -Force
        $changed = Get-Alias -Name $entry.Key -ErrorAction Stop
        if ($changed.Definition -ne 'Write-Output') {
            throw "LOCATION_ALIAS_PROVIDER_REBIND_FAILED name=$($entry.Key) actual=$($changed.Definition)"
        }
        $aliasProviderRebindObserved = $true
    }
    finally {
        Set-Alias -Name $entry.Key -Value $originalDefinition -Scope Local -Option $originalOptions -Force
    }

    $after = Get-Alias -Name $entry.Key -ErrorAction Stop
    if ($after.Definition -ne $originalDefinition -or $after.Options -ne $originalOptions) {
        throw "LOCATION_ALIAS_RESTORE_FAILED name=$($entry.Key) expectedDefinition=$originalDefinition actualDefinition=$($after.Definition) expectedOptions=$originalOptions actualOptions=$($after.Options)"
    }

    $observations += [pscustomobject]@{
        Alias = $entry.Key
        DefaultDefinition = $entry.Value
        OriginalOptions = [string]$originalOptions
        SetAliasRebindObserved = $setAliasRebindObserved
        AliasProviderRebindObserved = $aliasProviderRebindObserved
        AliasPrecedesFunctionObserved = $true
        OriginalAliasRestoredObserved = $true
    }
}

# Native command-precedence probe: exact cmdlet spellings are not immutable command
# identity when used unqualified. A same-name function hides the cmdlet. A
# module-qualified cmdlet call bypasses that shadow and is the stronger static
# authority for a distributed script.
$originalLocation = (Get-Location).Path
$setLocationShadow = & {
    function Set-Location {
        param([string]$Path)
        "shadow-set-location:$Path"
    }

    $resolved = Get-Command -Name Set-Location -ErrorAction Stop
    $beforeProvider = (Get-Location).Provider.Name
    $shadowOutput = Set-Location 'Variable:' | Out-String
    $afterUnqualifiedProvider = (Get-Location).Provider.Name

    Microsoft.PowerShell.Management\Set-Location -LiteralPath 'Variable:'
    $afterQualifiedProvider = (Get-Location).Provider.Name
    Microsoft.PowerShell.Management\Set-Location -LiteralPath $originalLocation

    [pscustomobject]@{
        ResolvedType = [string]$resolved.CommandType
        BeforeProvider = [string]$beforeProvider
        AfterUnqualifiedProvider = [string]$afterUnqualifiedProvider
        AfterQualifiedProvider = [string]$afterQualifiedProvider
        ShadowOutput = [string]$shadowOutput.Trim()
    }
}
if ($setLocationShadow.ResolvedType -ne 'Function') {
    throw "SET_LOCATION_FUNCTION_SHADOW_NOT_OBSERVED type=$($setLocationShadow.ResolvedType)"
}
if ($setLocationShadow.AfterUnqualifiedProvider -eq 'Variable') {
    throw 'UNQUALIFIED_SET_LOCATION_BYPASSED_FUNCTION_SHADOW'
}
if ($setLocationShadow.ShadowOutput -notmatch '^shadow-set-location:Variable:$') {
    throw "SET_LOCATION_FUNCTION_SHADOW_OUTPUT_MISMATCH output=$($setLocationShadow.ShadowOutput)"
}
if ($setLocationShadow.AfterQualifiedProvider -ne 'Variable') {
    throw "MODULE_QUALIFIED_SET_LOCATION_DID_NOT_REACH_VARIABLE_PROVIDER provider=$($setLocationShadow.AfterQualifiedProvider)"
}

$pushLocationShadow = & {
    function Push-Location {
        param([string]$Path)
        "shadow-push-location:$Path"
    }

    $resolved = Get-Command -Name Push-Location -ErrorAction Stop
    $beforeProvider = (Get-Location).Provider.Name
    $shadowOutput = Push-Location 'Variable:' | Out-String
    $afterUnqualifiedProvider = (Get-Location).Provider.Name

    Microsoft.PowerShell.Management\Push-Location -LiteralPath 'Variable:'
    $afterQualifiedProvider = (Get-Location).Provider.Name
    Microsoft.PowerShell.Management\Pop-Location
    $afterQualifiedPopPath = (Get-Location).Path

    [pscustomobject]@{
        ResolvedType = [string]$resolved.CommandType
        BeforeProvider = [string]$beforeProvider
        AfterUnqualifiedProvider = [string]$afterUnqualifiedProvider
        AfterQualifiedProvider = [string]$afterQualifiedProvider
        AfterQualifiedPopPath = [string]$afterQualifiedPopPath
        ShadowOutput = [string]$shadowOutput.Trim()
    }
}
if ($pushLocationShadow.ResolvedType -ne 'Function') {
    throw "PUSH_LOCATION_FUNCTION_SHADOW_NOT_OBSERVED type=$($pushLocationShadow.ResolvedType)"
}
if ($pushLocationShadow.AfterUnqualifiedProvider -eq 'Variable') {
    throw 'UNQUALIFIED_PUSH_LOCATION_BYPASSED_FUNCTION_SHADOW'
}
if ($pushLocationShadow.ShadowOutput -notmatch '^shadow-push-location:Variable:$') {
    throw "PUSH_LOCATION_FUNCTION_SHADOW_OUTPUT_MISMATCH output=$($pushLocationShadow.ShadowOutput)"
}
if ($pushLocationShadow.AfterQualifiedProvider -ne 'Variable') {
    throw "MODULE_QUALIFIED_PUSH_LOCATION_DID_NOT_REACH_VARIABLE_PROVIDER provider=$($pushLocationShadow.AfterQualifiedProvider)"
}
if ($pushLocationShadow.AfterQualifiedPopPath -ne $originalLocation) {
    throw "MODULE_QUALIFIED_POP_LOCATION_DID_NOT_RESTORE_ORIGINAL_PATH expected=$originalLocation actual=$($pushLocationShadow.AfterQualifiedPopPath)"
}

$result = [ordered]@{
    component = 'powershell-location-alias-resolution-canary'
    schemaVersion = 3
    psEdition = [string]$PSVersionTable.PSEdition
    psVersion = [string]$PSVersionTable.PSVersion
    osVersion = [string][Environment]::OSVersion.Version
    defaultAliasesObserved = $true
    aliasesAreSessionMutableObserved = $true
    setAliasRebindPreservingOptionsObserved = $true
    aliasProviderRebindObserved = $true
    aliasPrecedesFunctionObserved = $true
    allScopeOptionMustBePreservedObserved = $true
    staticAliasExecutionAuthorityAccepted = $false
    priorSessionAliasStateKnownToStaticAnalyzer = $false
    unqualifiedSetLocationCanBeFunctionShadowedObserved = $true
    unqualifiedPushLocationCanBeFunctionShadowedObserved = $true
    moduleQualifiedSetLocationBypassesFunctionShadowObserved = $true
    moduleQualifiedPushLocationBypassesFunctionShadowObserved = $true
    unqualifiedCanonicalLocationCommandImmutableIdentityAccepted = $false
    moduleQualifiedCanonicalLocationCommandIdentityAccepted = $true
    observations = $observations
}

$result | ConvertTo-Json -Depth 6 -Compress
Write-Host 'POWERSHELL_LOCATION_ALIAS_RESOLUTION_CANARY_PASS'
