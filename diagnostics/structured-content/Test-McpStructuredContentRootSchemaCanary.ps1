param(
    [Parameter(Mandatory = $true)][string]$ShellLabel,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Json([string]$Path, [object]$Object) {
    $full = [IO.Path]::GetFullPath($Path)
    $dir = Split-Path -Parent $full
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($full, ($Object | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}

$base = [ordered]@{
    schemaVersion = 1
    component = 'public-windows-mcp-structured-content-root-schema-canary'
    diagnosticOnly = $true
    shellLabel = $ShellLabel
    powerShellEdition = $PSVersionTable.PSEdition
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    osVersion = [Environment]::OSVersion.VersionString
}

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion -lt [version]'7.4.0') {
    $base['cases'] = @()
    $base['acceptanceBoundary'] = [ordered]@{
        productionSchemaValidationHostAccepted = $false
        windowsPowerShell51RejectedAsAcceptedSchemaValidator = ($PSVersionTable.PSEdition -eq 'Desktop')
        arbitraryJsonRootSchemaBehaviorExercised = $false
        mcpStructuredContentAnyJsonValueAccepted = $false
        semanticToolAccepted = $false
        windowsFinalStateAccepted = $false
    }
    Write-Json $OutputPath $base
    $base
    return
}

$cases = @(
    [ordered]@{ name='object'; validJson='{"value":1}'; invalidJson='{"value":"x"}'; schema='{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","required":["value"],"properties":{"value":{"type":"integer"}},"additionalProperties":false}' },
    [ordered]@{ name='array'; validJson='[1,2]'; invalidJson='[1,"x"]'; schema='{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"array","items":{"type":"integer"},"minItems":2}' },
    [ordered]@{ name='string'; validJson='"ok"'; invalidJson='"no"'; schema='{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"string","pattern":"^ok$"}' },
    [ordered]@{ name='number'; validJson='2'; invalidJson='0'; schema='{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"number","minimum":1}' },
    [ordered]@{ name='boolean'; validJson='true'; invalidJson='false'; schema='{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"boolean","const":true}' },
    [ordered]@{ name='null'; validJson='null'; invalidJson='0'; schema='{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"null"}' }
)

$observed = @()
foreach ($case in $cases) {
    $valid = [bool](Test-Json -Json $case.validJson -Schema $case.schema -ErrorAction SilentlyContinue)
    $invalid = [bool](Test-Json -Json $case.invalidJson -Schema $case.schema -ErrorAction SilentlyContinue)
    if (-not $valid) { throw "Valid $($case.name) structuredContent root was rejected by Test-Json." }
    if ($invalid) { throw "Invalid $($case.name) structuredContent root was accepted by Test-Json." }
    $observed += [ordered]@{
        rootType = $case.name
        validCaseAccepted = $valid
        invalidCaseRejected = (-not $invalid)
    }
}

$base['cases'] = $observed
$base['acceptanceBoundary'] = [ordered]@{
    productionSchemaValidationHostAccepted = $true
    powershellCore74OrNewerObserved = $true
    jsonSchema202012BehaviorExercised = $true
    objectRootAccepted = $true
    arrayRootAccepted = $true
    stringRootAccepted = $true
    numberRootAccepted = $true
    booleanRootAccepted = $true
    nullRootAccepted = $true
    arbitraryJsonRootSchemaBehaviorExercised = $true
    mcpStructuredContentAnyJsonValueAccepted = $true
    requestStartGenerationBindingProven = $false
    processOwnedResponseCaptureProven = $false
    responseOriginAuthenticated = $false
    semanticToolAccepted = $false
    windowsFinalStateAccepted = $false
}
Write-Json $OutputPath $base
$base
