param(
    [Parameter(Mandatory = $true)][string]$FramePlanReceiptPath,
    [Parameter(Mandatory = $true)][string]$ExpectedFramePlanReceiptSha256,
    [Parameter(Mandatory = $true)][System.IO.Stream]$TargetStream,
    [Parameter(Mandatory = $true)][string]$ReceiptPath,
    [ValidateRange(100, 30000)][int]$WriteTimeoutMs = 5000,
    [string]$ExpectedProtocolVersion = '2026-07-28',
    [ValidateSet('stdio')][string]$Transport = 'stdio'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$strictHelper = Join-Path $scriptRoot 'Get-BraintrustStrictJsonScalar.ps1'
$canonicalHelper = Join-Path $scriptRoot 'ConvertTo-BraintrustCanonicalJson.ps1'
foreach ($requiredFile in @($strictHelper, $canonicalHelper)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required stdio write-attempt dependency was not found: $requiredFile"
    }
}
. $strictHelper
. $canonicalHelper

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Sha256([string]$Value, [string]$FieldPath) {
    Assert-True ($Value -match '^[0-9a-fA-F]{64}$') "JSON field '$FieldPath' must contain a 64-hex SHA-256 value."
    return $Value.ToLowerInvariant()
}

function Get-NormalizedFullPath([string]$Path) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) 'Evidence path must not be empty.'
    return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-RecordedPath([string]$OwnerReceiptPath, [string]$RecordedPath) {
    if ([System.IO.Path]::IsPathRooted($RecordedPath)) { return Get-NormalizedFullPath $RecordedPath }
    return Get-NormalizedFullPath (Join-Path (Split-Path -Parent (Get-NormalizedFullPath $OwnerReceiptPath)) $RecordedPath)
}

function Get-FileSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required evidence file was not found: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function Get-TextSha256([string]$Text) {
    if ($null -eq $Text) { $Text = '' }
    return Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Assert-NoReparsePointInExistingAncestorChain([string]$Path) {
    $candidate = Get-NormalizedFullPath $Path
    while (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        $parent = [System.IO.Directory]::GetParent($candidate)
        if ($null -eq $parent) { break }
        $candidate = $parent.FullName
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { throw "Unable to resolve an existing path ancestor for: $Path" }
    $current = New-Object System.IO.DirectoryInfo($candidate)
    while ($null -ne $current) {
        if (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Stdio write-attempt evidence path traverses a reparse point: $($current.FullName)" }
        $current = $current.Parent
    }
}

function Assert-LocalFixedDirectory([string]$Path) {
    Assert-True ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) 'Stdio write-attempt recording requires native Windows.'
    $full = Get-NormalizedFullPath $Path
    Assert-True (-not $full.StartsWith('\\', [System.StringComparison]::Ordinal)) 'Stdio write-attempt directory must not be a UNC path.'
    $root = [System.IO.Path]::GetPathRoot($full)
    Assert-True (-not [string]::IsNullOrWhiteSpace($root)) 'Stdio write-attempt directory must have a local drive root.'
    $drive = New-Object System.IO.DriveInfo($root)
    Assert-True ($drive.DriveType -eq [System.IO.DriveType]::Fixed) 'Stdio write-attempt directory must be on a fixed local drive.'
    Assert-NoReparsePointInExistingAncestorChain $full
    return $full
}

function Assert-PathWithinDirectory([string]$Path, [string]$Directory, [string]$FieldPath) {
    $fullPath = Get-NormalizedFullPath $Path
    $fullDirectory = (Get-NormalizedFullPath $Directory).TrimEnd([char]'\', [char]'/')
    $prefix = $fullDirectory + [System.IO.Path]::DirectorySeparatorChar
    Assert-True ($fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) "$FieldPath must remain under the trusted frame-plan directory."
    return $fullPath
}

Assert-True ($ExpectedProtocolVersion -eq '2026-07-28') 'This stdio write-attempt gate supports only MCP 2026-07-28.'
Assert-True ($Transport -eq 'stdio') 'This write-attempt gate supports only stdio.'
Assert-True ($null -ne $TargetStream) 'TargetStream is required.'
Assert-True ($TargetStream.CanWrite) 'TargetStream must be writable before a write attempt is made.'
$expectedFramePlanSha256 = Assert-Sha256 $ExpectedFramePlanReceiptSha256 'ExpectedFramePlanReceiptSha256'

$framePlanPath = Get-NormalizedFullPath $FramePlanReceiptPath
$framePlanSha256 = Get-FileSha256 $framePlanPath
Assert-True ($framePlanSha256 -eq $expectedFramePlanSha256) 'Stdio frame-plan receipt SHA-256 differs from the externally expected digest.'
try {
    $framePlan = Assert-BraintrustJsonObjectValue -Value ((Get-Content -LiteralPath $framePlanPath -Raw) | ConvertFrom-Json -ErrorAction Stop) -FieldPath 'framePlan'
} catch {
    throw "Stdio frame-plan receipt is not valid JSON: $($_.Exception.Message)"
}
Assert-True ((Get-BraintrustRequiredJsonString -Object $framePlan -Name 'component' -FieldPath 'framePlan.component') -eq 'windows-mcp-multi-server-stdio-tool-call-frame-plan') 'Stdio frame-plan component is invalid.'
Assert-True ((Get-BraintrustRequiredJsonInteger -Object $framePlan -Name 'schemaVersion' -FieldPath 'framePlan.schemaVersion') -ge 1) 'Stdio frame-plan schema is too old.'
Assert-True ((Get-BraintrustRequiredJsonString -Object $framePlan -Name 'expectedProtocolVersion' -FieldPath 'framePlan.expectedProtocolVersion') -eq $ExpectedProtocolVersion) 'Stdio frame-plan protocol version differs from write-attempt gate.'
Assert-True ((Get-BraintrustRequiredJsonString -Object $framePlan -Name 'transport' -FieldPath 'framePlan.transport') -eq $Transport) 'Stdio frame-plan transport differs from write-attempt gate.'

$framingBoundary = Get-BraintrustRequiredJsonObject -Object $framePlan -Name 'framingBoundary' -FieldPath 'framePlan.framingBoundary'
foreach ($requiredTrue in @('stdioFramePlanAccepted','jsonRpcToolsCallShapeAccepted','requiredRequestMetaPresent','utf8EncodedAccepted','newlineDelimitedJsonRpcAccepted','exactlyOneTrailingLfAccepted','noEmbeddedLfBytesAccepted','noCarriageReturnBytesAccepted','utf8BomAbsentAccepted')) {
    Assert-True (Get-BraintrustRequiredJsonBoolean -Object $framingBoundary -Name $requiredTrue -FieldPath "framePlan.framingBoundary.$requiredTrue") "Stdio frame-plan flag '$requiredTrue' was not true."
}
foreach ($requiredFalse in @('wireFrameBytesPersisted','actualTransportWriteObserved','wireRequestSent','deliveryOutcomeKnown','liveCatalogGenerationCurrentAtFrameConstructionProven','generationCurrentAtActualWireSendProven','downstreamPhysicalServerIdentityAccepted','authorizationContextAccepted','humanApprovalAccepted','toolExecutionAuthorized','exactlyOnceToolSideEffectProven','responseValidationGenerationAccepted','semanticToolAccepted','windowsFinalStateAccepted')) {
    Assert-True (-not (Get-BraintrustRequiredJsonBoolean -Object $framingBoundary -Name $requiredFalse -FieldPath "framePlan.framingBoundary.$requiredFalse")) "Stdio frame plan must not pre-accept '$requiredFalse'."
}

$requestBinding = Get-BraintrustRequiredJsonObject -Object $framePlan -Name 'requestBinding' -FieldPath 'framePlan.requestBinding'
$requestId = Get-BraintrustRequiredJsonString -Object $requestBinding -Name 'requestId' -FieldPath 'framePlan.requestBinding.requestId'
$rawToolName = Get-BraintrustRequiredJsonString -Object $requestBinding -Name 'rawProtocolToolName' -FieldPath 'framePlan.requestBinding.rawProtocolToolName'
$generationRouteIdentitySha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $requestBinding -Name 'generationRouteIdentitySha256' -FieldPath 'framePlan.requestBinding.generationRouteIdentitySha256') 'framePlan.requestBinding.generationRouteIdentitySha256'
$argumentsSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $requestBinding -Name 'argumentsCanonicalSha256' -FieldPath 'framePlan.requestBinding.argumentsCanonicalSha256') 'framePlan.requestBinding.argumentsCanonicalSha256'
$requestBodyExpectedSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $requestBinding -Name 'requestBodyCanonicalSha256' -FieldPath 'framePlan.requestBinding.requestBodyCanonicalSha256') 'framePlan.requestBinding.requestBodyCanonicalSha256'
$requestBodyExpectedLength = Get-BraintrustRequiredJsonInteger -Object $requestBinding -Name 'requestBodyUtf8ByteLength' -FieldPath 'framePlan.requestBinding.requestBodyUtf8ByteLength'
$frameExpectedSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $requestBinding -Name 'wireFrameSha256' -FieldPath 'framePlan.requestBinding.wireFrameSha256') 'framePlan.requestBinding.wireFrameSha256'
$frameExpectedLength = Get-BraintrustRequiredJsonInteger -Object $requestBinding -Name 'wireFrameByteLength' -FieldPath 'framePlan.requestBinding.wireFrameByteLength'
Assert-True (-not (Get-BraintrustRequiredJsonBoolean -Object $requestBinding -Name 'modelVisibleExposedNameAcceptedAsWireToolName' -FieldPath 'framePlan.requestBinding.modelVisibleExposedNameAcceptedAsWireToolName')) 'Model-visible route must not become the MCP stdio wire tool name.'

$frameSource = Get-BraintrustRequiredJsonObject -Object $framePlan -Name 'sourceEvidence' -FieldPath 'framePlan.sourceEvidence'
$wireAttemptPath = Resolve-RecordedPath -OwnerReceiptPath $framePlanPath -RecordedPath (Get-BraintrustRequiredJsonString -Object $frameSource -Name 'wireAttemptReceiptPath' -FieldPath 'framePlan.sourceEvidence.wireAttemptReceiptPath')
$wireAttemptExpectedSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $frameSource -Name 'wireAttemptReceiptSha256' -FieldPath 'framePlan.sourceEvidence.wireAttemptReceiptSha256') 'framePlan.sourceEvidence.wireAttemptReceiptSha256'
$approvalRequestPath = Resolve-RecordedPath -OwnerReceiptPath $framePlanPath -RecordedPath (Get-BraintrustRequiredJsonString -Object $frameSource -Name 'approvalRequestReceiptPath' -FieldPath 'framePlan.sourceEvidence.approvalRequestReceiptPath')
$approvalRequestExpectedSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $frameSource -Name 'approvalRequestReceiptSha256' -FieldPath 'framePlan.sourceEvidence.approvalRequestReceiptSha256') 'framePlan.sourceEvidence.approvalRequestReceiptSha256'
$wireAttemptSha256 = Get-FileSha256 $wireAttemptPath
$approvalRequestSha256 = Get-FileSha256 $approvalRequestPath
Assert-True ($wireAttemptSha256 -eq $wireAttemptExpectedSha256) 'Wire-attempt receipt bytes differ from frame-plan evidence before write.'
Assert-True ($approvalRequestSha256 -eq $approvalRequestExpectedSha256) 'Approval-request receipt bytes differ from frame-plan evidence before write.'

try {
    $wireAttempt = Assert-BraintrustJsonObjectValue -Value ((Get-Content -LiteralPath $wireAttemptPath -Raw) | ConvertFrom-Json -ErrorAction Stop) -FieldPath 'wireAttempt'
    $approvalRequest = Assert-BraintrustJsonObjectValue -Value ((Get-Content -LiteralPath $approvalRequestPath -Raw) | ConvertFrom-Json -ErrorAction Stop) -FieldPath 'approvalRequest'
} catch {
    throw "Stdio write-attempt upstream evidence is not valid JSON: $($_.Exception.Message)"
}
Assert-True ((Get-BraintrustRequiredJsonString -Object $wireAttempt -Name 'component' -FieldPath 'wireAttempt.component') -eq 'windows-mcp-multi-server-approval-effectuation-wire-attempt') 'Wire-attempt component is invalid.'
$attemptBinding = Get-BraintrustRequiredJsonObject -Object $wireAttempt -Name 'attemptBinding' -FieldPath 'wireAttempt.attemptBinding'
Assert-True ((Get-BraintrustRequiredJsonString -Object $attemptBinding -Name 'outcomeKind' -FieldPath 'wireAttempt.attemptBinding.outcomeKind') -eq 'wire-attempt-started') 'Wire-attempt receipt does not retain wire-attempt-started outcome.'
$approvalDecisionId = Get-BraintrustRequiredJsonString -Object $attemptBinding -Name 'approvalDecisionId' -FieldPath 'wireAttempt.attemptBinding.approvalDecisionId'
Assert-True ([string]::Equals($requestId, ('approval-decision:' + $approvalDecisionId), [System.StringComparison]::Ordinal)) 'Frame-plan request id no longer correlates to the exact approval decision.'
Assert-True ((Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $attemptBinding -Name 'generationRouteIdentitySha256' -FieldPath 'wireAttempt.attemptBinding.generationRouteIdentitySha256') 'wireAttempt.attemptBinding.generationRouteIdentitySha256') -eq $generationRouteIdentitySha256) 'Wire-attempt generation-route identity differs from frame plan.'
Assert-True ([string]::Equals((Get-BraintrustRequiredJsonString -Object $attemptBinding -Name 'rawProtocolToolName' -FieldPath 'wireAttempt.attemptBinding.rawProtocolToolName'), $rawToolName, [System.StringComparison]::Ordinal)) 'Wire-attempt raw MCP tool name differs from frame plan.'
Assert-True ((Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $attemptBinding -Name 'argumentsCanonicalSha256' -FieldPath 'wireAttempt.attemptBinding.argumentsCanonicalSha256') 'wireAttempt.attemptBinding.argumentsCanonicalSha256') -eq $argumentsSha256) 'Wire-attempt arguments digest differs from frame plan.'

$wireSource = Get-BraintrustRequiredJsonObject -Object $wireAttempt -Name 'sourceEvidence' -FieldPath 'wireAttempt.sourceEvidence'
$preflightPath = Resolve-RecordedPath -OwnerReceiptPath $wireAttemptPath -RecordedPath (Get-BraintrustRequiredJsonString -Object $wireSource -Name 'multiServerExecutionPreflightReceiptPath' -FieldPath 'wireAttempt.sourceEvidence.multiServerExecutionPreflightReceiptPath')
$preflightExpectedSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $wireSource -Name 'multiServerExecutionPreflightReceiptSha256' -FieldPath 'wireAttempt.sourceEvidence.multiServerExecutionPreflightReceiptSha256') 'wireAttempt.sourceEvidence.multiServerExecutionPreflightReceiptSha256'
$preflightSha256 = Get-FileSha256 $preflightPath
Assert-True ($preflightSha256 -eq $preflightExpectedSha256) 'Execution-preflight receipt bytes differ at stdio write boundary.'
try {
    $preflight = Assert-BraintrustJsonObjectValue -Value ((Get-Content -LiteralPath $preflightPath -Raw) | ConvertFrom-Json -ErrorAction Stop) -FieldPath 'preflight'
} catch {
    throw "Execution-preflight receipt is not valid JSON: $($_.Exception.Message)"
}
$preflightSource = Get-BraintrustRequiredJsonObject -Object $preflight -Name 'sourceEvidence' -FieldPath 'preflight.sourceEvidence'
$generationPath = Resolve-RecordedPath -OwnerReceiptPath $preflightPath -RecordedPath (Get-BraintrustRequiredJsonString -Object $preflightSource -Name 'catalogGenerationReceiptPath' -FieldPath 'preflight.sourceEvidence.catalogGenerationReceiptPath')
$generationExpectedSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $preflightSource -Name 'catalogGenerationReceiptSha256' -FieldPath 'preflight.sourceEvidence.catalogGenerationReceiptSha256') 'preflight.sourceEvidence.catalogGenerationReceiptSha256'
$observedPath = Resolve-RecordedPath -OwnerReceiptPath $preflightPath -RecordedPath (Get-BraintrustRequiredJsonString -Object $preflightSource -Name 'observedToolsListResponsePath' -FieldPath 'preflight.sourceEvidence.observedToolsListResponsePath')
$observedExpectedSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $preflightSource -Name 'observedToolsListResponseSha256' -FieldPath 'preflight.sourceEvidence.observedToolsListResponseSha256') 'preflight.sourceEvidence.observedToolsListResponseSha256'
$generationSha256 = Get-FileSha256 $generationPath
$observedSha256 = Get-FileSha256 $observedPath
Assert-True ($generationSha256 -eq $generationExpectedSha256) 'Catalog-generation receipt bytes drifted before stdio write.'
Assert-True ($observedSha256 -eq $observedExpectedSha256) 'Observed tools/list bytes drifted before stdio write.'

Assert-True ((Get-BraintrustRequiredJsonString -Object $approvalRequest -Name 'component' -FieldPath 'approvalRequest.component') -eq 'windows-mcp-multi-server-tool-approval-request') 'Approval-request component is invalid.'
$approvalBody = Get-BraintrustRequiredJsonObject -Object $approvalRequest -Name 'approvalRequest' -FieldPath 'approvalRequest.approvalRequest'
Assert-True ([string]::Equals((Get-BraintrustRequiredJsonString -Object $approvalBody -Name 'rawProtocolToolName' -FieldPath 'approvalRequest.approvalRequest.rawProtocolToolName'), $rawToolName, [System.StringComparison]::Ordinal)) 'Approval-request raw MCP tool name differs from frame plan.'
Assert-True ((Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $approvalBody -Name 'argumentsCanonicalSha256' -FieldPath 'approvalRequest.approvalRequest.argumentsCanonicalSha256') 'approvalRequest.approvalRequest.argumentsCanonicalSha256') -eq $argumentsSha256) 'Approval-request arguments digest differs from frame plan.'
$argumentsObject = Get-BraintrustRequiredJsonObject -Object $approvalBody -Name 'arguments' -FieldPath 'approvalRequest.approvalRequest.arguments'
$argumentsCanonicalJson = ConvertTo-BraintrustCanonicalJson (ConvertTo-BraintrustCanonicalValue $argumentsObject)
Assert-True ((Get-BraintrustUtf8Sha256 $argumentsCanonicalJson) -eq $argumentsSha256) 'Approval-request arguments no longer match the accepted post-validation digest.'

$request = [ordered]@{
    id = $requestId
    jsonrpc = '2.0'
    method = 'tools/call'
    params = [ordered]@{
        _meta = [ordered]@{
            'io.modelcontextprotocol/clientCapabilities' = [ordered]@{}
            'io.modelcontextprotocol/protocolVersion' = $ExpectedProtocolVersion
        }
        arguments = ConvertTo-BraintrustCanonicalValue $argumentsObject
        name = $rawToolName
    }
}
$requestCanonicalJson = ConvertTo-BraintrustCanonicalJson $request
Assert-True ($requestCanonicalJson.IndexOf("`r", [System.StringComparison]::Ordinal) -lt 0) 'Canonical stdio request contains CR.'
Assert-True ($requestCanonicalJson.IndexOf("`n", [System.StringComparison]::Ordinal) -lt 0) 'Canonical stdio request contains embedded LF.'
[byte[]]$requestBytes = [System.Text.Encoding]::UTF8.GetBytes($requestCanonicalJson)
[byte[]]$frameBytes = New-Object byte[] ($requestBytes.Length + 1)
[System.Buffer]::BlockCopy($requestBytes, 0, $frameBytes, 0, $requestBytes.Length)
$frameBytes[$frameBytes.Length - 1] = 0x0A
$requestBodySha256 = Get-BytesSha256 $requestBytes
$frameSha256 = Get-BytesSha256 $frameBytes
Assert-True ($requestBodySha256 -eq $requestBodyExpectedSha256) 'Rebuilt request body SHA-256 differs from frame plan.'
Assert-True ($requestBytes.Length -eq $requestBodyExpectedLength) 'Rebuilt request body length differs from frame plan.'
Assert-True ($frameSha256 -eq $frameExpectedSha256) 'Rebuilt stdio frame SHA-256 differs from frame plan.'
Assert-True ($frameBytes.Length -eq $frameExpectedLength) 'Rebuilt stdio frame length differs from frame plan.'
Assert-True ($frameBytes[$frameBytes.Length - 1] -eq 0x0A) 'Rebuilt stdio frame does not end in LF.'
Assert-True (@($frameBytes | Where-Object { $_ -eq 0x0D }).Count -eq 0) 'Rebuilt stdio frame contains CR.'
Assert-True (@($frameBytes | Where-Object { $_ -eq 0x0A }).Count -eq 1) 'Rebuilt stdio frame must contain exactly one LF delimiter.'

# Immediately before the one local stream write, re-hash all load-bearing evidence bytes.
Assert-True ((Get-FileSha256 $framePlanPath) -eq $framePlanSha256) 'Frame-plan receipt changed immediately before stdio write.'
Assert-True ((Get-FileSha256 $wireAttemptPath) -eq $wireAttemptSha256) 'Wire-attempt receipt changed immediately before stdio write.'
Assert-True ((Get-FileSha256 $approvalRequestPath) -eq $approvalRequestSha256) 'Approval-request receipt changed immediately before stdio write.'
Assert-True ((Get-FileSha256 $preflightPath) -eq $preflightSha256) 'Execution-preflight receipt changed immediately before stdio write.'
Assert-True ((Get-FileSha256 $generationPath) -eq $generationSha256) 'Catalog-generation receipt changed immediately before stdio write.'
Assert-True ((Get-FileSha256 $observedPath) -eq $observedSha256) 'Observed tools/list bytes changed immediately before stdio write.'

$writeInvocations = 0
$localWriteCompleted = $false
$localWriteFaultObserved = $false
$localWriteCompletionUnknown = $false
$writeFaultType = $null
$writeFaultMessageSha256 = $null
try {
    $writeInvocations++
    $writeTask = $TargetStream.WriteAsync($frameBytes, 0, $frameBytes.Length)
    try {
        $settled = $writeTask.Wait($WriteTimeoutMs)
        if (-not $settled) {
            $localWriteCompletionUnknown = $true
        } elseif ($writeTask.IsCanceled) {
            $localWriteFaultObserved = $true
            $writeFaultType = 'TaskCanceledException'
            $writeFaultMessageSha256 = Get-TextSha256 'WriteAsync task was canceled.'
        } elseif ($writeTask.IsFaulted) {
            $localWriteFaultObserved = $true
            $baseException = $writeTask.Exception.GetBaseException()
            $writeFaultType = $baseException.GetType().FullName
            $writeFaultMessageSha256 = Get-TextSha256 $baseException.Message
        } else {
            $localWriteCompleted = $true
        }
    } catch [System.AggregateException] {
        $localWriteFaultObserved = $true
        $baseException = $_.Exception.GetBaseException()
        $writeFaultType = $baseException.GetType().FullName
        $writeFaultMessageSha256 = Get-TextSha256 $baseException.Message
    }
} catch {
    $localWriteFaultObserved = $true
    $writeFaultType = $_.Exception.GetType().FullName
    $writeFaultMessageSha256 = Get-TextSha256 $_.Exception.Message
}
Assert-True ($writeInvocations -eq 1) 'Exactly one caller WriteAsync invocation must be attempted.'
Assert-True (-not ($localWriteCompleted -and $localWriteFaultObserved)) 'Write attempt cannot be both completed and faulted.'
Assert-True (-not ($localWriteCompleted -and $localWriteCompletionUnknown)) 'Write attempt cannot be both completed and completion-unknown.'
Assert-True (-not ($localWriteFaultObserved -and $localWriteCompletionUnknown)) 'Write attempt cannot be both faulted and completion-unknown.'

# Re-hash evidence again after the bounded local write observation. Timeout is deliberately not retried.
Assert-True ((Get-FileSha256 $framePlanPath) -eq $framePlanSha256) 'Frame-plan receipt changed during stdio write attempt.'
Assert-True ((Get-FileSha256 $wireAttemptPath) -eq $wireAttemptSha256) 'Wire-attempt receipt changed during stdio write attempt.'
Assert-True ((Get-FileSha256 $approvalRequestPath) -eq $approvalRequestSha256) 'Approval-request receipt changed during stdio write attempt.'
Assert-True ((Get-FileSha256 $preflightPath) -eq $preflightSha256) 'Execution-preflight receipt changed during stdio write attempt.'
Assert-True ((Get-FileSha256 $generationPath) -eq $generationSha256) 'Catalog-generation receipt changed during stdio write attempt.'
Assert-True ((Get-FileSha256 $observedPath) -eq $observedSha256) 'Observed tools/list bytes changed during stdio write attempt.'

$trustedDirectory = Assert-LocalFixedDirectory (Split-Path -Parent $framePlanPath)
$receiptPathFull = Assert-PathWithinDirectory -Path $ReceiptPath -Directory $trustedDirectory -FieldPath 'ReceiptPath'
Assert-True (-not [string]::Equals($receiptPathFull, $framePlanPath, [System.StringComparison]::OrdinalIgnoreCase)) 'Write-attempt receipt path must differ from frame-plan receipt path.'
Assert-NoReparsePointInExistingAncestorChain $receiptPathFull
$receiptDirectory = Split-Path -Parent $receiptPathFull
if ($receiptDirectory) { New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null }

$receipt = [ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-multi-server-stdio-frame-write-attempt'
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    expectedProtocolVersion = $ExpectedProtocolVersion
    transport = $Transport
    sourceEvidence = [ordered]@{
        framePlanReceiptPath = $framePlanPath
        framePlanReceiptSha256 = $framePlanSha256
        wireAttemptReceiptPath = $wireAttemptPath
        wireAttemptReceiptSha256 = $wireAttemptSha256
        approvalRequestReceiptPath = $approvalRequestPath
        approvalRequestReceiptSha256 = $approvalRequestSha256
        multiServerExecutionPreflightReceiptPath = $preflightPath
        multiServerExecutionPreflightReceiptSha256 = $preflightSha256
        catalogGenerationReceiptPath = $generationPath
        catalogGenerationReceiptSha256 = $generationSha256
        observedToolsListResponsePath = $observedPath
        observedToolsListResponseSha256 = $observedSha256
    }
    requestBinding = [ordered]@{
        requestId = $requestId
        generationRouteIdentitySha256 = $generationRouteIdentitySha256
        rawProtocolToolName = $rawToolName
        argumentsCanonicalSha256 = $argumentsSha256
        requestBodyCanonicalSha256 = $requestBodySha256
        requestBodyUtf8ByteLength = $requestBytes.Length
        wireFrameSha256 = $frameSha256
        wireFrameByteLength = $frameBytes.Length
        modelVisibleExposedNameAcceptedAsWireToolName = $false
    }
    writeObservation = [ordered]@{
        writeAsyncInvocationCount = $writeInvocations
        exactlyOneCallerWriteInvocationAccepted = $true
        writeTimeoutMs = $WriteTimeoutMs
        localStreamWriteCompleted = $localWriteCompleted
        localWriteFaultObserved = $localWriteFaultObserved
        localWriteCompletionUnknown = $localWriteCompletionUnknown
        writeFaultType = $writeFaultType
        writeFaultMessageSha256 = $writeFaultMessageSha256
        automaticRetryAccepted = $false
        flushOperationPerformed = $false
        targetStreamDisposedByGate = $false
    }
    acceptanceBoundary = [ordered]@{
        stdioFrameWriteAttemptRecorded = $true
        frameBytesRebuiltAndMatchedPlan = $true
        loadBearingEvidenceRehashedImmediatelyBeforeWrite = $true
        loadBearingEvidenceRehashedAfterWriteObservation = $true
        localStreamWriteCompletionAccepted = $localWriteCompleted
        atomicOsPipeWriteProven = $false
        serverReadObserved = $false
        mcpServerReceiptProven = $false
        wireRequestSent = $false
        deliveryOutcomeKnown = $false
        toolExecutionObserved = $false
        generationCurrentAtActualWriteProven = $false
        downstreamPhysicalServerIdentityAccepted = $false
        authorizationContextAccepted = $false
        humanApprovalAccepted = $false
        toolExecutionAuthorized = $false
        exactlyOnceToolSideEffectProven = $false
        semanticToolAccepted = $false
        windowsFinalStateAccepted = $false
    }
}
[System.IO.File]::WriteAllText($receiptPathFull, ($receipt | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))

if ($localWriteFaultObserved) { throw "MCP_STDIO_LOCAL_WRITE_FAULT: receipt=$receiptPathFull faultType=$writeFaultType" }
if ($localWriteCompletionUnknown) { throw "MCP_STDIO_LOCAL_WRITE_COMPLETION_UNKNOWN: receipt=$receiptPathFull; automatic retry is forbidden because the outstanding write may still complete." }
$receipt
