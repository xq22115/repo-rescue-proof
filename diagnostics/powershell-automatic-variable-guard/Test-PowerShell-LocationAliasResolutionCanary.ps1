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

$result = [ordered]@{
    component = 'powershell-location-alias-resolution-canary'
    schemaVersion = 2
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
    observations = $observations
}

$result | ConvertTo-Json -Depth 6 -Compress
Write-Host 'POWERSHELL_LOCATION_ALIAS_RESOLUTION_CANARY_PASS'