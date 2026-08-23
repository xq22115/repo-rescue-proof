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

    $setAliasResult = & {
        Set-Alias -Name $entry.Key -Value Write-Output -Scope Local -Force
        $changed = Get-Command -Name $entry.Key -ErrorAction Stop
        [pscustomobject]@{
            Type = [string]$changed.CommandType
            Definition = [string]$changed.Definition
        }
    }
    if ($setAliasResult.Type -ne 'Alias' -or $setAliasResult.Definition -ne 'Write-Output') {
        throw "LOCATION_ALIAS_SET_ALIAS_REBIND_FAILED name=$($entry.Key) type=$($setAliasResult.Type) definition=$($setAliasResult.Definition)"
    }

    $aliasProviderResult = & {
        Set-Item -Path ("Alias:{0}" -f $entry.Key) -Value Write-Output -Force
        $changed = Get-Command -Name $entry.Key -ErrorAction Stop
        [pscustomobject]@{
            Type = [string]$changed.CommandType
            Definition = [string]$changed.Definition
        }
    }
    if ($aliasProviderResult.Type -ne 'Alias' -or $aliasProviderResult.Definition -ne 'Write-Output') {
        throw "LOCATION_ALIAS_PROVIDER_REBIND_FAILED name=$($entry.Key) type=$($aliasProviderResult.Type) definition=$($aliasProviderResult.Definition)"
    }

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

    $after = Get-Alias -Name $entry.Key -ErrorAction Stop
    if ($after.Definition -ne $entry.Value) {
        throw "LOCATION_ALIAS_SCOPE_RESTORE_FAILED name=$($entry.Key) expected=$($entry.Value) actual=$($after.Definition)"
    }

    $observations += [pscustomobject]@{
        Alias = $entry.Key
        DefaultDefinition = $entry.Value
        SetAliasRebindObserved = $true
        AliasProviderRebindObserved = $true
        AliasPrecedesFunctionObserved = $true
        ChildScopeRestoreObserved = $true
    }
}

$result = [ordered]@{
    component = 'powershell-location-alias-resolution-canary'
    schemaVersion = 1
    psEdition = [string]$PSVersionTable.PSEdition
    psVersion = [string]$PSVersionTable.PSVersion
    osVersion = [string][Environment]::OSVersion.Version
    defaultAliasesObserved = $true
    aliasesAreSessionMutableObserved = $true
    setAliasRebindObserved = $true
    aliasProviderRebindObserved = $true
    aliasPrecedesFunctionObserved = $true
    staticAliasExecutionAuthorityAccepted = $false
    priorSessionAliasStateKnownToStaticAnalyzer = $false
    observations = $observations
}

$result | ConvertTo-Json -Depth 6 -Compress
Write-Host 'POWERSHELL_LOCATION_ALIAS_RESOLUTION_CANARY_PASS'