param(
    [Parameter(Mandatory = $true)][string]$NearWireRevalidationReceiptPath,
    [Parameter(Mandatory = $true)][string]$ExpectedNearWireRevalidationReceiptSha256,
    [Parameter(Mandatory = $true)][string]$FramePlanReceiptPath,
    [Parameter(Mandatory = $true)][string]$ExpectedFramePlanReceiptSha256,
    [Parameter(Mandatory = $true)][System.IO.Stream]$TargetStream,
    [Parameter(Mandatory = $true)][string]$ChildWriteAttemptReceiptPath,
    [Parameter(Mandatory = $true)][string]$ReceiptPath,
    [ValidateRange(100, 30000)][int]$WriteTimeoutMs = 5000,
    [string]$ExpectedProtocolVersion = '2026-07-28',
    [ValidateSet('stdio')][string]$Transport = 'stdio'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$strictHelper = Join-Path $scriptRoot 'Get-BraintrustStrictJsonScalar.ps1'
$childWriteGate = Join-Path $scriptRoot 'Invoke-Windows-Mcp-MultiServerStdioFrameWriteAttempt.ps1'
foreach ($requiredFile in @($strictHelper, $childWriteGate)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required near-wire stdio write dependency was not found: $requiredFile"
    }
}
. $strictHelper

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Sha256([string]$Value, [string]$FieldPath) {
    Assert-True ($Value -match '^[0-9a-fA-F]{64}$') "JSON field '$FieldPath' must contain a 64-hex SHA-256 value."
    return $Value.ToLowerInvariant()
}

function Get-FullPath([string]$Path) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) 'Evidence path must not be empty.'
    return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-RecordedPath([string]$OwnerReceiptPath, [string]$RecordedPath) {
    if ([System.IO.Path]::IsPathRooted($RecordedPath)) { return Get-FullPath $RecordedPath }
    return Get-FullPath (Join-Path (Split-Path -Parent (Get-FullPath $OwnerReceiptPath)) $RecordedPath)
}

function Get-FileSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required evidence file was not found: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-PathEquivalent([string]$Actual, [string]$Expected, [string]$Message) {
    Assert-True ([string]::Equals((Get-FullPath $Actual), (Get-FullPath $Expected), [System.StringComparison]::OrdinalIgnoreCase)) $Message
}

Assert-True ($ExpectedProtocolVersion -eq '2026-07-28') 'Near-wire bound stdio write supports only MCP 2026-07-28.'
Assert-True ($Transport -eq 'stdio') 'Near-wire bound stdio write currently supports only stdio.'
Assert-True ($null -ne $TargetStream) 'TargetStream is required.'
Assert-True ($TargetStream.CanWrite) 'TargetStream must be writable.'

$nearWirePath = Get-FullPath $NearWireRevalidationReceiptPath
$framePlanPath = Get-FullPath $FramePlanReceiptPath
$childReceiptPath = Get-FullPath $ChildWriteAttemptReceiptPath
$receiptPathFull = Get-FullPath $ReceiptPath
$expectedNearWireSha256 = Assert-Sha256 $ExpectedNearWireRevalidationReceiptSha256 'ExpectedNearWireRevalidationReceiptSha256'
$expectedFramePlanSha256 = Assert-Sha256 $ExpectedFramePlanReceiptSha256 'ExpectedFramePlanReceiptSha256'
$nearWireSha256 = Get-FileSha256 $nearWirePath
$framePlanSha256 = Get-FileSha256 $framePlanPath
Assert-True ($nearWireSha256 -eq $expectedNearWireSha256) 'Near-wire revalidation receipt differs from the externally expected digest.'
Assert-True ($framePlanSha256 -eq $expectedFramePlanSha256) 'Frame-plan receipt differs from the externally expected digest.'
Assert-True (-not [string]::Equals($childReceiptPath, $receiptPathFull, [System.StringComparison]::OrdinalIgnoreCase)) 'Child and wrapper receipt paths must differ.'

try {
    $nearWire = Assert-BraintrustJsonObjectValue -Value ((Get-Content -LiteralPath $nearWirePath -Raw) | ConvertFrom-Json -ErrorAction Stop) -FieldPath 'nearWire'
    $framePlan = Assert-BraintrustJsonObjectValue -Value ((Get-Content -LiteralPath $framePlanPath -Raw) | ConvertFrom-Json -ErrorAction Stop) -FieldPath 'framePlan'
} catch {
    throw "Near-wire/write evidence is not valid JSON: $($_.Exception.Message)"
}

Assert-True ((Get-BraintrustRequiredJsonString -Object $nearWire -Name 'component' -FieldPath 'nearWire.component') -eq 'windows-mcp-near-wire-selected-tool-generation-revalidation') 'Near-wire revalidation component is invalid.'
Assert-True ((Get-BraintrustRequiredJsonInteger -Object $nearWire -Name 'schemaVersion' -FieldPath 'nearWire.schemaVersion') -ge 1) 'Near-wire revalidation schema is too old.'
Assert-True ((Get-BraintrustRequiredJsonString -Object $nearWire -Name 'expectedProtocolVersion' -FieldPath 'nearWire.expectedProtocolVersion') -eq $ExpectedProtocolVersion) 'Near-wire protocol differs from write protocol.'
Assert-True ((Get-BraintrustRequiredJsonString -Object $nearWire -Name 'transport' -FieldPath 'nearWire.transport') -eq $Transport) 'Near-wire transport differs from write transport.'
Assert-True (Get-BraintrustRequiredJsonBoolean -Object $nearWire -Name 'nearWireSelectedToolGenerationRevalidationAccepted' -FieldPath 'nearWire.nearWireSelectedToolGenerationRevalidationAccepted') 'Near-wire selected-tool generation revalidation was not accepted.'

Assert-True ((Get-BraintrustRequiredJsonString -Object $framePlan -Name 'component' -FieldPath 'framePlan.component') -eq 'windows-mcp-multi-server-stdio-tool-call-frame-plan') 'Frame-plan component is invalid.'
Assert-True ((Get-BraintrustRequiredJsonString -Object $framePlan -Name 'expectedProtocolVersion' -FieldPath 'framePlan.expectedProtocolVersion') -eq $ExpectedProtocolVersion) 'Frame-plan protocol differs from near-wire revalidation.'
Assert-True ((Get-BraintrustRequiredJsonString -Object $framePlan -Name 'transport' -FieldPath 'framePlan.transport') -eq $Transport) 'Frame-plan transport differs from near-wire revalidation.'

$frameRequest = Get-BraintrustRequiredJsonObject -Object $framePlan -Name 'requestBinding' -FieldPath 'framePlan.requestBinding'
$rawToolName = Get-BraintrustRequiredJsonString -Object $frameRequest -Name 'rawProtocolToolName' -FieldPath 'framePlan.requestBinding.rawProtocolToolName'
$generationRouteIdentitySha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $frameRequest -Name 'generationRouteIdentitySha256' -FieldPath 'framePlan.requestBinding.generationRouteIdentitySha256') 'framePlan.requestBinding.generationRouteIdentitySha256'
$argumentsCanonicalSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $frameRequest -Name 'argumentsCanonicalSha256' -FieldPath 'framePlan.requestBinding.argumentsCanonicalSha256') 'framePlan.requestBinding.argumentsCanonicalSha256'
Assert-True (-not (Get-BraintrustRequiredJsonBoolean -Object $frameRequest -Name 'modelVisibleExposedNameAcceptedAsWireToolName' -FieldPath 'framePlan.requestBinding.modelVisibleExposedNameAcceptedAsWireToolName')) 'Frame plan must not accept the model-visible route as the MCP wire name.'

$nearRoute = Get-BraintrustRequiredJsonObject -Object $nearWire -Name 'routeBinding' -FieldPath 'nearWire.routeBinding'
Assert-True ([string]::Equals((Get-BraintrustRequiredJsonString -Object $nearRoute -Name 'rawProtocolToolName' -FieldPath 'nearWire.routeBinding.rawProtocolToolName'), $rawToolName, [System.StringComparison]::Ordinal)) 'Near-wire raw MCP tool name differs from frame plan.'
Assert-True ((Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $nearRoute -Name 'priorGenerationRouteIdentitySha256' -FieldPath 'nearWire.routeBinding.priorGenerationRouteIdentitySha256') 'nearWire.routeBinding.priorGenerationRouteIdentitySha256') -eq $generationRouteIdentitySha256) 'Near-wire generation route differs from frame plan.'
Assert-True (-not (Get-BraintrustRequiredJsonBoolean -Object $nearRoute -Name 'exposedNameAcceptedAsWireToolName' -FieldPath 'nearWire.routeBinding.exposedNameAcceptedAsWireToolName')) 'Near-wire revalidation must not accept the model-visible route as the wire tool name.'

$nearSelected = Get-BraintrustRequiredJsonObject -Object $nearWire -Name 'selectedToolBinding' -FieldPath 'nearWire.selectedToolBinding'
Assert-True ((Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $nearSelected -Name 'argumentsCanonicalSha256' -FieldPath 'nearWire.selectedToolBinding.argumentsCanonicalSha256') 'nearWire.selectedToolBinding.argumentsCanonicalSha256') -eq $argumentsCanonicalSha256) 'Near-wire arguments digest differs from the frame plan.'
Assert-True (Get-BraintrustRequiredJsonBoolean -Object $nearSelected -Name 'selectedToolDefinitionMatchesApprovedPreflight' -FieldPath 'nearWire.selectedToolBinding.selectedToolDefinitionMatchesApprovedPreflight') 'Near-wire selected tool definition no longer matches approved preflight.'
Assert-True (Get-BraintrustRequiredJsonBoolean -Object $nearSelected -Name 'selectedInputSchemaMatchesApprovedPreflight' -FieldPath 'nearWire.selectedToolBinding.selectedInputSchemaMatchesApprovedPreflight') 'Near-wire selected input schema no longer matches approved preflight.'

$nearFreshness = Get-BraintrustRequiredJsonObject -Object $nearWire -Name 'freshnessBoundary' -FieldPath 'nearWire.freshnessBoundary'
foreach ($requiredTrue in @('nearWireGenerationReceiptGeneratedAfterExecutionPreflight','nearWireDirectLiveGenerationEvidenceAccepted','listChangedCanInvalidateAfterThisRevalidation','generationCanStillChangeAfterRevalidation')) {
    Assert-True (Get-BraintrustRequiredJsonBoolean -Object $nearFreshness -Name $requiredTrue -FieldPath "nearWire.freshnessBoundary.$requiredTrue") "Near-wire freshness flag '$requiredTrue' was not true."
}
foreach ($requiredFalse in @('freshDirectToolsListRequestObservedByThisReceipt','ttlUsedAsEffectuationAuthority','subscriptionNotificationUsedAsSoleFreshnessAuthority','generationCurrentAtActualWireSendProven')) {
    Assert-True (-not (Get-BraintrustRequiredJsonBoolean -Object $nearFreshness -Name $requiredFalse -FieldPath "nearWire.freshnessBoundary.$requiredFalse")) "Near-wire freshness boundary must not pre-accept '$requiredFalse'."
}

$nearBoundary = Get-BraintrustRequiredJsonObject -Object $nearWire -Name 'acceptanceBoundary' -FieldPath 'nearWire.acceptanceBoundary'
foreach ($requiredTrue in @('executionPreflightExactReceiptBound','newerGenerationEvidenceBound','selectedToolDefinitionRevalidated','selectedInputSchemaRevalidated','directLiveGenerationEvidenceRequiredForProduction')) {
    Assert-True (Get-BraintrustRequiredJsonBoolean -Object $nearBoundary -Name $requiredTrue -FieldPath "nearWire.acceptanceBoundary.$requiredTrue") "Near-wire acceptance flag '$requiredTrue' was not true."
}
foreach ($requiredFalse in @('downstreamPhysicalServerIdentityAccepted','authorizationContextAccepted','humanApprovalAccepted','toolExecutionAuthorized','wireRequestSent','responseValidationGenerationAccepted','semanticToolAccepted','windowsFinalStateAccepted')) {
    Assert-True (-not (Get-BraintrustRequiredJsonBoolean -Object $nearBoundary -Name $requiredFalse -FieldPath "nearWire.acceptanceBoundary.$requiredFalse")) "Near-wire revalidation must not pre-accept '$requiredFalse'."
}

$nearSource = Get-BraintrustRequiredJsonObject -Object $nearWire -Name 'sourceEvidence' -FieldPath 'nearWire.sourceEvidence'
$nearPreflightPath = Resolve-RecordedPath -OwnerReceiptPath $nearWirePath -RecordedPath (Get-BraintrustRequiredJsonString -Object $nearSource -Name 'multiServerExecutionPreflightReceiptPath' -FieldPath 'nearWire.sourceEvidence.multiServerExecutionPreflightReceiptPath')
$nearPreflightSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $nearSource -Name 'multiServerExecutionPreflightReceiptSha256' -FieldPath 'nearWire.sourceEvidence.multiServerExecutionPreflightReceiptSha256') 'nearWire.sourceEvidence.multiServerExecutionPreflightReceiptSha256'
$nearGenerationPath = Resolve-RecordedPath -OwnerReceiptPath $nearWirePath -RecordedPath (Get-BraintrustRequiredJsonString -Object $nearSource -Name 'nearWireCatalogGenerationReceiptPath' -FieldPath 'nearWire.sourceEvidence.nearWireCatalogGenerationReceiptPath')
$nearGenerationSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $nearSource -Name 'nearWireCatalogGenerationReceiptSha256' -FieldPath 'nearWire.sourceEvidence.nearWireCatalogGenerationReceiptSha256') 'nearWire.sourceEvidence.nearWireCatalogGenerationReceiptSha256'
$nearObservedPath = Resolve-RecordedPath -OwnerReceiptPath $nearWirePath -RecordedPath (Get-BraintrustRequiredJsonString -Object $nearSource -Name 'nearWireObservedToolsListResponsePath' -FieldPath 'nearWire.sourceEvidence.nearWireObservedToolsListResponsePath')
$nearObservedSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $nearSource -Name 'nearWireObservedToolsListResponseSha256' -FieldPath 'nearWire.sourceEvidence.nearWireObservedToolsListResponseSha256') 'nearWire.sourceEvidence.nearWireObservedToolsListResponseSha256'
Assert-True ((Get-FileSha256 $nearPreflightPath) -eq $nearPreflightSha256) 'Near-wire execution-preflight receipt bytes changed before write integration.'
Assert-True ((Get-FileSha256 $nearGenerationPath) -eq $nearGenerationSha256) 'Near-wire catalog-generation receipt bytes changed before write integration.'
Assert-True ((Get-FileSha256 $nearObservedPath) -eq $nearObservedSha256) 'Near-wire tools/list bytes changed before write integration.'

$frameSource = Get-BraintrustRequiredJsonObject -Object $framePlan -Name 'sourceEvidence' -FieldPath 'framePlan.sourceEvidence'
$wireAttemptPath = Resolve-RecordedPath -OwnerReceiptPath $framePlanPath -RecordedPath (Get-BraintrustRequiredJsonString -Object $frameSource -Name 'wireAttemptReceiptPath' -FieldPath 'framePlan.sourceEvidence.wireAttemptReceiptPath')
$wireAttemptExpectedSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $frameSource -Name 'wireAttemptReceiptSha256' -FieldPath 'framePlan.sourceEvidence.wireAttemptReceiptSha256') 'framePlan.sourceEvidence.wireAttemptReceiptSha256'
Assert-True ((Get-FileSha256 $wireAttemptPath) -eq $wireAttemptExpectedSha256) 'Frame-plan wire-attempt receipt changed before near-wire integration.'
$wireAttempt = Assert-BraintrustJsonObjectValue -Value ((Get-Content -LiteralPath $wireAttemptPath -Raw) | ConvertFrom-Json -ErrorAction Stop) -FieldPath 'wireAttempt'
$wireSource = Get-BraintrustRequiredJsonObject -Object $wireAttempt -Name 'sourceEvidence' -FieldPath 'wireAttempt.sourceEvidence'
$wirePreflightPath = Resolve-RecordedPath -OwnerReceiptPath $wireAttemptPath -RecordedPath (Get-BraintrustRequiredJsonString -Object $wireSource -Name 'multiServerExecutionPreflightReceiptPath' -FieldPath 'wireAttempt.sourceEvidence.multiServerExecutionPreflightReceiptPath')
$wirePreflightSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $wireSource -Name 'multiServerExecutionPreflightReceiptSha256' -FieldPath 'wireAttempt.sourceEvidence.multiServerExecutionPreflightReceiptSha256') 'wireAttempt.sourceEvidence.multiServerExecutionPreflightReceiptSha256'
Assert-PathEquivalent $nearPreflightPath $wirePreflightPath 'Near-wire and frame-plan effectuation evidence refer to different execution-preflight receipts.'
Assert-True ($nearPreflightSha256 -eq $wirePreflightSha256) 'Near-wire and frame-plan effectuation evidence bind different execution-preflight receipt digests.'

# Re-hash the near-wire freshness evidence immediately before entering the lower-level single-write gate.
Assert-True ((Get-FileSha256 $nearWirePath) -eq $nearWireSha256) 'Near-wire revalidation receipt changed immediately before child write.'
Assert-True ((Get-FileSha256 $nearGenerationPath) -eq $nearGenerationSha256) 'Near-wire catalog-generation receipt changed immediately before child write.'
Assert-True ((Get-FileSha256 $nearObservedPath) -eq $nearObservedSha256) 'Near-wire tools/list bytes changed immediately before child write.'
Assert-True ((Get-FileSha256 $framePlanPath) -eq $framePlanSha256) 'Frame-plan receipt changed immediately before child write.'

$childReceipt = & $childWriteGate `
    -FramePlanReceiptPath $framePlanPath `
    -ExpectedFramePlanReceiptSha256 $framePlanSha256 `
    -TargetStream $TargetStream `
    -ReceiptPath $childReceiptPath `
    -WriteTimeoutMs $WriteTimeoutMs `
    -ExpectedProtocolVersion $ExpectedProtocolVersion `
    -Transport $Transport

$childReceiptSha256 = Get-FileSha256 $childReceiptPath
$child = Assert-BraintrustJsonObjectValue -Value ((Get-Content -LiteralPath $childReceiptPath -Raw) | ConvertFrom-Json -ErrorAction Stop) -FieldPath 'childWrite'
Assert-True ((Get-BraintrustRequiredJsonString -Object $child -Name 'component' -FieldPath 'childWrite.component') -eq 'windows-mcp-multi-server-stdio-frame-write-attempt') 'Child write-attempt component is invalid.'
$childRequest = Get-BraintrustRequiredJsonObject -Object $child -Name 'requestBinding' -FieldPath 'childWrite.requestBinding'
Assert-True ([string]::Equals((Get-BraintrustRequiredJsonString -Object $childRequest -Name 'rawProtocolToolName' -FieldPath 'childWrite.requestBinding.rawProtocolToolName'), $rawToolName, [System.StringComparison]::Ordinal)) 'Child write-attempt raw tool name differs from near-wire/frame plan.'
Assert-True ((Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $childRequest -Name 'generationRouteIdentitySha256' -FieldPath 'childWrite.requestBinding.generationRouteIdentitySha256') 'childWrite.requestBinding.generationRouteIdentitySha256') -eq $generationRouteIdentitySha256) 'Child write-attempt generation route differs from near-wire/frame plan.'
Assert-True ((Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $childRequest -Name 'argumentsCanonicalSha256' -FieldPath 'childWrite.requestBinding.argumentsCanonicalSha256') 'childWrite.requestBinding.argumentsCanonicalSha256') -eq $argumentsCanonicalSha256) 'Child write-attempt arguments differ from near-wire/frame plan.'
$childBoundary = Get-BraintrustRequiredJsonObject -Object $child -Name 'acceptanceBoundary' -FieldPath 'childWrite.acceptanceBoundary'
Assert-True (Get-BraintrustRequiredJsonBoolean -Object $childBoundary -Name 'stdioFrameWriteAttemptRecorded' -FieldPath 'childWrite.acceptanceBoundary.stdioFrameWriteAttemptRecorded') 'Child stdio write attempt was not recorded.'
Assert-True (Get-BraintrustRequiredJsonBoolean -Object $childBoundary -Name 'loadBearingEvidenceRehashedImmediatelyBeforeWrite' -FieldPath 'childWrite.acceptanceBoundary.loadBearingEvidenceRehashedImmediatelyBeforeWrite') 'Child did not re-hash its own load-bearing evidence immediately before write.'
Assert-True (Get-BraintrustRequiredJsonBoolean -Object $childBoundary -Name 'loadBearingEvidenceRehashedAfterWriteObservation' -FieldPath 'childWrite.acceptanceBoundary.loadBearingEvidenceRehashedAfterWriteObservation') 'Child did not re-hash its own load-bearing evidence after write observation.'
Assert-True (-not (Get-BraintrustRequiredJsonBoolean -Object $childBoundary -Name 'generationCurrentAtActualWriteProven' -FieldPath 'childWrite.acceptanceBoundary.generationCurrentAtActualWriteProven')) 'Child write attempt must not claim atomic generation freshness.'
Assert-True (-not (Get-BraintrustRequiredJsonBoolean -Object $childBoundary -Name 'wireRequestSent' -FieldPath 'childWrite.acceptanceBoundary.wireRequestSent')) 'Local stream-write completion must not be promoted to server delivery.'

# Re-hash the newer freshness evidence after the bounded child write observation as well.
Assert-True ((Get-FileSha256 $nearWirePath) -eq $nearWireSha256) 'Near-wire revalidation receipt changed during child write attempt.'
Assert-True ((Get-FileSha256 $nearGenerationPath) -eq $nearGenerationSha256) 'Near-wire catalog-generation receipt changed during child write attempt.'
Assert-True ((Get-FileSha256 $nearObservedPath) -eq $nearObservedSha256) 'Near-wire tools/list bytes changed during child write attempt.'
Assert-True ((Get-FileSha256 $framePlanPath) -eq $framePlanSha256) 'Frame-plan receipt changed during child write attempt.'

$receiptDirectory = Split-Path -Parent $receiptPathFull
if ($receiptDirectory) { New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null }
$receipt = [ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-near-wire-bound-stdio-frame-write-attempt'
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    expectedProtocolVersion = $ExpectedProtocolVersion
    transport = $Transport
    sourceEvidence = [ordered]@{
        nearWireRevalidationReceiptPath = $nearWirePath
        nearWireRevalidationReceiptSha256 = $nearWireSha256
        nearWireCatalogGenerationReceiptPath = $nearGenerationPath
        nearWireCatalogGenerationReceiptSha256 = $nearGenerationSha256
        nearWireObservedToolsListResponsePath = $nearObservedPath
        nearWireObservedToolsListResponseSha256 = $nearObservedSha256
        framePlanReceiptPath = $framePlanPath
        framePlanReceiptSha256 = $framePlanSha256
        childWriteAttemptReceiptPath = $childReceiptPath
        childWriteAttemptReceiptSha256 = $childReceiptSha256
        multiServerExecutionPreflightReceiptPath = $nearPreflightPath
        multiServerExecutionPreflightReceiptSha256 = $nearPreflightSha256
    }
    requestBinding = [ordered]@{
        generationRouteIdentitySha256 = $generationRouteIdentitySha256
        rawProtocolToolName = $rawToolName
        argumentsCanonicalSha256 = $argumentsCanonicalSha256
        modelVisibleExposedNameAcceptedAsWireToolName = $false
    }
    freshnessBinding = [ordered]@{
        newerDirectLiveGenerationEvidenceRequired = $true
        selectedToolDefinitionRevalidated = $true
        selectedInputSchemaRevalidated = $true
        ttlUsedAsEffectuationAuthority = $false
        subscriptionNotificationUsedAsSoleFreshnessAuthority = $false
        freshDirectToolsListRequestObservedByThisWrapper = $false
        listChangedCanInvalidateAfterThisBinding = $true
        generationCurrentAtActualWireSendProven = $false
    }
    acceptanceBoundary = [ordered]@{
        nearWireRevalidationRequiredAndBound = $true
        nearWireEvidenceRehashedImmediatelyBeforeChildWrite = $true
        nearWireEvidenceRehashedAfterChildWrite = $true
        childSingleWriteAttemptAccepted = $true
        legacyStandaloneWriteAttemptProductionAuthorityAccepted = $false
        actualTransportWriteObserved = $true
        wireRequestSent = $false
        deliveryOutcomeKnown = $false
        downstreamPhysicalServerIdentityAccepted = $false
        authorizationContextAccepted = $false
        humanApprovalAccepted = $false
        toolExecutionAuthorized = $false
        exactlyOnceToolSideEffectProven = $false
        responseValidationGenerationAccepted = $false
        semanticToolAccepted = $false
        windowsFinalStateAccepted = $false
    }
}
[System.IO.File]::WriteAllText($receiptPathFull, ($receipt | ConvertTo-Json -Depth 24), (New-Object System.Text.UTF8Encoding($false)))
$receipt
