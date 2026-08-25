param(
    [Parameter(Mandatory = $true)]
    [string]$StaticRegistrationReceiptPath,

    [Parameter(Mandatory = $true)]
    [string]$ObservedToolsListResponsePath,

    [Parameter(Mandatory = $true)]
    [string]$ReceiptPath,

    [string]$ExpectedProtocolVersion = '2026-07-28',

    [datetime]$ObservedAtUtc = ([datetime]::UtcNow)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$canonicalHelper = Join-Path $scriptRoot 'ConvertTo-BraintrustCanonicalJson.ps1'
$strictScalarHelper = Join-Path $scriptRoot 'Get-BraintrustStrictJsonScalar.ps1'
if (-not (Test-Path -LiteralPath $canonicalHelper -PathType Leaf)) {
    throw 'ConvertTo-BraintrustCanonicalJson.ps1 was not found.'
}
if (-not (Test-Path -LiteralPath $strictScalarHelper -PathType Leaf)) {
    throw 'Get-BraintrustStrictJsonScalar.ps1 was not found.'
}
. $canonicalHelper
. $strictScalarHelper

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-ObservedToolShape {
    param(
        [Parameter(Mandatory = $true)][object]$Tool,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $fieldBase = "observedEnvelope.result.tools[$Index]"
    $toolObject = Assert-BraintrustJsonObjectValue -Value $Tool -FieldPath $fieldBase
    Get-BraintrustRequiredJsonString -Object $toolObject -Name 'name' -FieldPath "$fieldBase.name" | Out-Null
    Get-BraintrustOptionalJsonString -Object $toolObject -Name 'title' -FieldPath "$fieldBase.title" -AllowEmpty | Out-Null
    Get-BraintrustOptionalJsonString -Object $toolObject -Name 'description' -FieldPath "$fieldBase.description" -AllowEmpty | Out-Null
    Get-BraintrustRequiredJsonObject -Object $toolObject -Name 'inputSchema' -FieldPath "$fieldBase.inputSchema" | Out-Null
    Get-BraintrustOptionalJsonObject -Object $toolObject -Name 'outputSchema' -FieldPath "$fieldBase.outputSchema" | Out-Null
    Get-BraintrustOptionalJsonObject -Object $toolObject -Name 'annotations' -FieldPath "$fieldBase.annotations" | Out-Null
    Get-BraintrustOptionalJsonObject -Object $toolObject -Name '_meta' -FieldPath "$fieldBase._meta" | Out-Null
    return $toolObject
}

function Get-NormalizedToolNames($Tools, [string]$SourceName) {
    $names = @()
    $index = 0
    foreach ($tool in @($Tools)) {
        $toolObject = Assert-BraintrustJsonObjectValue -Value $tool -FieldPath "$SourceName[$index]"
        $name = Get-BraintrustRequiredJsonString -Object $toolObject -Name 'name' -FieldPath "$SourceName[$index].name"
        $names += $name
        $index++
    }

    $normalized = @($names | ForEach-Object { $_.ToLowerInvariant() })
    $duplicates = @($normalized | Group-Object | Where-Object { $_.Count -gt 1 })
    Assert-True ($duplicates.Count -eq 0) "$SourceName contains duplicate tool names."
    return @($names)
}

function Get-CanonicalToolCatalogFingerprint($Tools) {
    $entries = @()
    $index = 0
    foreach ($tool in @($Tools)) {
        $toolObject = Assert-BraintrustJsonObjectValue -Value $tool -FieldPath "observed tools[$index]"
        $name = Get-BraintrustRequiredJsonString -Object $toolObject -Name 'name' -FieldPath "observed tools[$index].name"
        $description = Get-BraintrustOptionalJsonString -Object $toolObject -Name 'description' -FieldPath "observed tools[$index].description" -AllowEmpty
        $inputSchema = Get-BraintrustRequiredJsonObject -Object $toolObject -Name 'inputSchema' -FieldPath "observed tools[$index].inputSchema"
        $outputSchema = Get-BraintrustOptionalJsonObject -Object $toolObject -Name 'outputSchema' -FieldPath "observed tools[$index].outputSchema"
        $entries += [ordered]@{
            name = $name
            description = if ($null -eq $description) { '' } else { $description }
            inputSchema = ConvertTo-BraintrustCanonicalValue $inputSchema
            outputSchema = ConvertTo-BraintrustCanonicalValue $outputSchema
        }
        $index++
    }

    $entries = @($entries | Sort-Object { ([string]$_.name).ToLowerInvariant() })
    $canonicalJson = ConvertTo-BraintrustCanonicalJson $entries
    return [ordered]@{
        canonicalJsonSha256 = Get-BraintrustUtf8Sha256 $canonicalJson
        toolCount = $entries.Count
    }
}

Assert-True (Test-Path -LiteralPath $StaticRegistrationReceiptPath -PathType Leaf) 'StaticRegistrationReceiptPath was not found.'
Assert-True (Test-Path -LiteralPath $ObservedToolsListResponsePath -PathType Leaf) 'ObservedToolsListResponsePath was not found.'
Assert-True (-not [string]::IsNullOrWhiteSpace($ExpectedProtocolVersion)) 'ExpectedProtocolVersion must not be empty.'
Assert-True ($ExpectedProtocolVersion -eq '2026-07-28') 'This observed tool-catalog gate currently supports only MCP 2026-07-28 cache/result semantics.'

$staticReceipt = (Get-Content -LiteralPath $StaticRegistrationReceiptPath -Raw) | ConvertFrom-Json
$staticReceipt = Assert-BraintrustJsonObjectValue -Value $staticReceipt -FieldPath 'staticReceipt'
$staticComponent = Get-BraintrustRequiredJsonString -Object $staticReceipt -Name 'component' -FieldPath 'staticReceipt.component'
Assert-True ($staticComponent -eq 'windows-mcp-static-registration') 'Static receipt component is not windows-mcp-static-registration.'
Assert-True (Get-BraintrustRequiredJsonBoolean -Object $staticReceipt -Name 'staticRegistrationAccepted' -FieldPath 'staticReceipt.staticRegistrationAccepted') 'Static registration receipt is not accepted.'
Assert-True (Get-BraintrustRequiredJsonBoolean -Object $staticReceipt -Name 'staticToolCatalogAccepted' -FieldPath 'staticReceipt.staticToolCatalogAccepted') 'Static tool catalog receipt is not accepted.'

$staticComparison = Get-BraintrustRequiredJsonObject -Object $staticReceipt -Name 'toolCatalogComparison' -FieldPath 'staticReceipt.toolCatalogComparison'
$staticFingerprint = Get-BraintrustRequiredJsonString -Object $staticComparison -Name 'staticCatalogCanonicalSha256' -FieldPath 'staticReceipt.toolCatalogComparison.staticCatalogCanonicalSha256'
Assert-True ($staticFingerprint -match '^[0-9a-fA-F]{64}$') 'Static receipt staticCatalogCanonicalSha256 is not a 64-hex SHA-256 value.'
$staticComparisonMode = Get-BraintrustRequiredJsonString -Object $staticComparison -Name 'comparisonMode' -FieldPath 'staticReceipt.toolCatalogComparison.comparisonMode'
Assert-True ($staticComparisonMode -eq 'recursive-ordinal-object-key-sort-v1') 'Static receipt uses an unsupported canonical comparison mode.'

$observedEnvelope = (Get-Content -LiteralPath $ObservedToolsListResponsePath -Raw) | ConvertFrom-Json
$observedEnvelope = Assert-BraintrustJsonObjectValue -Value $observedEnvelope -FieldPath 'observedEnvelope'
$jsonRpcVersion = Get-BraintrustRequiredJsonString -Object $observedEnvelope -Name 'jsonrpc' -FieldPath 'observedEnvelope.jsonrpc'
Assert-True ($jsonRpcVersion -eq '2.0') 'Observed tools/list response must be a JSON-RPC 2.0 envelope.'
Assert-True ($null -eq (Get-PropertyValue $observedEnvelope 'error')) 'Observed tools/list response contains a JSON-RPC error.'

$result = Get-BraintrustRequiredJsonObject -Object $observedEnvelope -Name 'result' -FieldPath 'observedEnvelope.result'
$resultType = Get-BraintrustRequiredJsonString -Object $result -Name 'resultType' -FieldPath 'observedEnvelope.result.resultType'
Assert-True ($resultType -eq 'complete') 'Observed tools/list resultType must be complete for catalog acceptance.'

$tools = @(Get-BraintrustRequiredJsonArray -Object $result -Name 'tools' -FieldPath 'observedEnvelope.result.tools')
Assert-True ($tools.Count -gt 0) 'Observed tools/list result must contain at least one tool.'
$shapeIndex = 0
foreach ($tool in $tools) {
    Assert-ObservedToolShape -Tool $tool -Index $shapeIndex | Out-Null
    $shapeIndex++
}
$toolNames = @(Get-NormalizedToolNames $tools 'observedEnvelope.result.tools')

$nextCursor = Get-BraintrustOptionalJsonString -Object $result -Name 'nextCursor' -FieldPath 'observedEnvelope.result.nextCursor' -AllowEmpty
Assert-True ([string]::IsNullOrWhiteSpace($nextCursor)) 'Observed tools/list response is paginated; a single page cannot prove full-catalog equivalence.'

$ttlMs = Get-BraintrustRequiredJsonInteger -Object $result -Name 'ttlMs' -FieldPath 'observedEnvelope.result.ttlMs'
Assert-True ($ttlMs -ge 0) 'Observed tools/list ttlMs must be greater than or equal to zero.'

$cacheScope = Get-BraintrustRequiredJsonString -Object $result -Name 'cacheScope' -FieldPath 'observedEnvelope.result.cacheScope'
Assert-True ($cacheScope -in @('public', 'private')) 'Observed tools/list cacheScope must be public or private.'

$observedFingerprint = Get-CanonicalToolCatalogFingerprint $tools
$catalogMatchesStatic = ([string]$observedFingerprint.canonicalJsonSha256 -eq $staticFingerprint)
Assert-True $catalogMatchesStatic 'Observed tools/list canonical catalog fingerprint differs from the accepted static registration catalog.'

$observedAt = $ObservedAtUtc.ToUniversalTime()
$nowUtc = [datetime]::UtcNow
$freshUntil = $null
$freshnessTimeRepresentable = $true
try {
    $freshUntil = $observedAt.AddMilliseconds([double]$ttlMs)
} catch {
    $freshnessTimeRepresentable = $false
}
$protocolFreshAtReceiptGeneration = ($freshnessTimeRepresentable -and $ttlMs -gt 0 -and $nowUtc -lt $freshUntil)
$crossAuthorizationContextReuseAllowedByServer = ($cacheScope -eq 'public')

# This receipt consumes an artifact. It does not prove where that artifact came from,
# which authorization context produced it, or whether a shared intermediary served it.
# Keep protocol cache freshness separate from security provenance/reuse acceptance.
$responseOriginProven = $false
$authorizationContextBound = $false
$serverIdentityBoundToObservedResponse = $false
$securityReuseAccepted = $false
$securityReuseDecision = if ($cacheScope -eq 'private') {
    'rejected-unproven-origin-auth-context-and-server-identity'
} else {
    'rejected-unproven-origin-and-server-identity'
}

$receiptDirectory = Split-Path -Parent $ReceiptPath
if ($receiptDirectory) { New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null }

$receipt = [ordered]@{
    schemaVersion = 4
    component = 'windows-mcp-observed-tool-catalog'
    generatedAtUtc = $nowUtc.ToString('o')
    expectedProtocolVersion = $ExpectedProtocolVersion
    scalarValidation = [ordered]@{
        strictStaticReceiptBooleanTypesValidated = $true
        strictIdentityAndProtocolStringTypesValidated = $true
        strictTtlJsonNumericTypeValidated = $true
        stringBooleanObjectArrayNumericCoercionAllowed = $false
        ttlVerifierRepresentation = 'System.Decimal'
        ttlValuesOutsideSystemDecimalRangeAccepted = $false
    }
    shapeValidation = [ordered]@{
        strictStaticReceiptAndComparisonObjectShapesValidated = $true
        strictObservedEnvelopeAndResultObjectShapesValidated = $true
        strictObservedToolsArrayAndEntryObjectShapesValidated = $true
        strictObservedToolSchemaObjectShapesValidated = $true
        strictOptionalAnnotationsAndMetaObjectShapesValidated = $true
        scalarObjectArrayShapeCoercionAllowed = $false
    }
    sourceEvidence = [ordered]@{
        staticRegistrationReceiptPath = [System.IO.Path]::GetFullPath($StaticRegistrationReceiptPath)
        staticRegistrationReceiptSha256 = Get-FileSha256 $StaticRegistrationReceiptPath
        observedToolsListResponsePath = [System.IO.Path]::GetFullPath($ObservedToolsListResponsePath)
        observedToolsListResponseSha256 = Get-FileSha256 $ObservedToolsListResponsePath
        responseOriginProvenByThisReceipt = $responseOriginProven
        directNetworkRoundTripProvenByThisReceipt = $false
        authorizationContextBoundByThisReceipt = $authorizationContextBound
        serverIdentityBoundToObservedResponseByThisReceipt = $serverIdentityBoundToObservedResponse
    }
    result = [ordered]@{
        jsonrpc = $jsonRpcVersion
        resultType = $resultType
        toolCount = $tools.Count
        toolNamesInObservedOrder = @($toolNames)
        paginated = $false
    }
    cacheEvidence = [ordered]@{
        ttlMs = $ttlMs
        ttlSchemaType = 'integer'
        ttlIntegerValidated = $true
        ttlJsonScalarTypeValidated = $true
        cacheScope = $cacheScope
        cacheScopeJsonStringTypeValidated = $true
        observedAtUtc = $observedAt.ToString('o')
        freshnessTimeRepresentable = $freshnessTimeRepresentable
        freshUntilUtc = if ($freshnessTimeRepresentable) { $freshUntil.ToString('o') } else { $null }
        reusableAtReceiptGeneration = $protocolFreshAtReceiptGeneration
        reusableAtReceiptGenerationMeaning = 'protocol-freshness-only-not-security-reuse'
        protocolFreshAtReceiptGeneration = $protocolFreshAtReceiptGeneration
        ttlIsFreshnessHintNotGuarantee = $true
        notificationInvalidationCheckedByThisReceipt = $false
        crossAuthorizationContextReuseAllowedByServer = $crossAuthorizationContextReuseAllowedByServer
        securityReuseAccepted = $securityReuseAccepted
        securityReuseRequiresProvenResponseOrigin = $true
        securityReuseRequiresBoundAuthorizationContextForPrivateScope = $true
        securityReuseRequiresVerifiedServerIdentity = $true
        securityReuseDecision = $securityReuseDecision
    }
    catalogComparison = [ordered]@{
        comparisonMode = $staticComparisonMode
        staticCatalogCanonicalSha256 = $staticFingerprint
        observedCatalogCanonicalSha256 = [string]$observedFingerprint.canonicalJsonSha256
        canonicalFingerprintMatchesStatic = $catalogMatchesStatic
        objectPropertyOrderNormalized = $true
        arrayOrderingPreserved = $true
        singleObservationProvesDeterministicServerOrdering = $false
        canonicalComparisonProvesJsonSchemaSemanticEquivalence = $false
    }
    sideEffectsPerformed = $false
    observedToolCatalogAccepted = $true
    observedToolCatalogMatchesStatic = $true
    acceptanceBoundary = [ordered]@{
        staticRegistrationEvidenceAccepted = $true
        observedResponseStructureAccepted = $true
        observedResponseContainerShapesAccepted = $true
        observedCatalogMatchesStatic = $true
        directLiveNetworkResponseProven = $false
        cacheFreshnessProtocolAccepted = $protocolFreshAtReceiptGeneration
        cacheReuseForSecurityAcceptance = $securityReuseAccepted
        authorizationContextBound = $authorizationContextBound
        serverIdentityBoundToObservedResponse = $serverIdentityBoundToObservedResponse
        protocolRuntimeAccepted = $false
        deterministicOrderingRuntimeAccepted = $false
        semanticToolAccepted = $false
        osStateReadbackAccepted = $false
    }
}

$receiptJson = $receipt | ConvertTo-Json -Depth 12
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($ReceiptPath), $receiptJson, $utf8NoBom)
$receipt
