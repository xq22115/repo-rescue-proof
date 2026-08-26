param(
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$TargetProcess,
    [Parameter(Mandatory = $true)][string]$StdioSessionAffinityReceiptPath,
    [Parameter(Mandatory = $true)][string]$ExpectedStdioSessionAffinityReceiptSha256,
    [Parameter(Mandatory = $true)][string]$NearWireRevalidationReceiptPath,
    [Parameter(Mandatory = $true)][string]$ExpectedNearWireRevalidationReceiptSha256,
    [Parameter(Mandatory = $true)][string]$FramePlanReceiptPath,
    [Parameter(Mandatory = $true)][string]$ExpectedFramePlanReceiptSha256,
    [Parameter(Mandatory = $true)][string]$ChildWriteAttemptReceiptPath,
    [Parameter(Mandatory = $true)][string]$NearWireWriteReceiptPath,
    [Parameter(Mandatory = $true)][string]$ReceiptPath,
    [ValidateRange(100, 30000)][int]$WriteTimeoutMs = 5000,
    [string]$ExpectedProtocolVersion = '2026-07-28',
    [ValidateSet('stdio')][string]$Transport = 'stdio'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'MCP_STDIO_TRANSPORT_HOST_UNSUPPORTED: process-owned MCP stdio writes require PowerShell Core 7 or later; Windows PowerShell 5.1 is not accepted as an exact-byte stdio broker.'
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$strictHelper = Join-Path $scriptRoot 'Get-BraintrustStrictJsonScalar.ps1'
$nearWireWriteGate = Join-Path $scriptRoot 'Invoke-Windows-Mcp-NearWireBoundStdioFrameWriteAttempt.ps1'
foreach ($requiredFile in @($strictHelper, $nearWireWriteGate)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required process-owned stdio dependency was not found: $requiredFile"
    }
}
. $strictHelper

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Sha256([string]$Value, [string]$FieldPath) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($Value)) "$FieldPath is required."
    Assert-True ($Value -match '^[0-9a-fA-F]{64}$') "$FieldPath must be a 64-hex SHA-256 value."
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

function ConvertTo-UtcTimestamp([object]$Value, [string]$FieldPath) {
    Assert-True ($null -ne $Value) "$FieldPath is required."
    if ($Value -is [datetimeoffset]) { return ([datetimeoffset]$Value).ToUniversalTime() }
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) { $dt = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc) }
        return ([datetimeoffset]$dt.ToUniversalTime())
    }
    $parsed = [datetimeoffset]::MinValue
    $ok = [datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
    Assert-True $ok "$FieldPath must be an ISO-8601 timestamp."
    Assert-True ($parsed.Offset -eq [timespan]::Zero) "$FieldPath must represent UTC."
    return $parsed.ToUniversalTime()
}

function Read-StrictJsonObject([string]$Path, [string]$FieldPath) {
    try {
        return Assert-BraintrustJsonObjectValue -Value ((Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json -ErrorAction Stop) -FieldPath $FieldPath
    } catch {
        throw "$FieldPath is not valid strict JSON input: $($_.Exception.Message)"
    }
}

function Get-LiveProcessIdentity([System.Diagnostics.Process]$Process, [string]$FieldPath) {
    Assert-True ($null -ne $Process) "$FieldPath process object is required."
    $Process.Refresh()
    Assert-True (-not $Process.HasExited) "$FieldPath process exited before the stdio write boundary."

    $imagePath = $null
    try { $imagePath = [string]$Process.Path } catch {}
    if ([string]::IsNullOrWhiteSpace($imagePath)) {
        try { $imagePath = [string]$Process.MainModule.FileName } catch {}
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($imagePath)) "$FieldPath image path could not be observed."
    $imagePath = Get-FullPath $imagePath
    Assert-True (Test-Path -LiteralPath $imagePath -PathType Leaf) "$FieldPath image path no longer exists."
    $imageSha256 = Get-FileSha256 $imagePath
    $startTimeUtc = ([datetimeoffset]$Process.StartTime).ToUniversalTime()

    return [pscustomobject][ordered]@{
        pid = [int]$Process.Id
        startTimeUtc = $startTimeUtc
        imagePath = $imagePath
        imageBackingFileSha256 = $imageSha256
    }
}

Assert-True ($env:OS -eq 'Windows_NT') 'Process-owned stdio write binding only supports Windows.'
Assert-True ($ExpectedProtocolVersion -eq '2026-07-28') 'Process-owned stdio write binding currently supports only MCP 2026-07-28.'
Assert-True ($Transport -eq 'stdio') 'Process-owned stdio write binding currently supports only stdio.'
Assert-True ($null -ne $TargetProcess) 'TargetProcess is required.'

$sessionPath = Get-FullPath $StdioSessionAffinityReceiptPath
$nearWirePath = Get-FullPath $NearWireRevalidationReceiptPath
$framePlanPath = Get-FullPath $FramePlanReceiptPath
$childWritePath = Get-FullPath $ChildWriteAttemptReceiptPath
$nearWireWritePath = Get-FullPath $NearWireWriteReceiptPath
$receiptFullPath = Get-FullPath $ReceiptPath
$expectedSessionSha256 = Assert-Sha256 $ExpectedStdioSessionAffinityReceiptSha256 'ExpectedStdioSessionAffinityReceiptSha256'
$expectedNearWireSha256 = Assert-Sha256 $ExpectedNearWireRevalidationReceiptSha256 'ExpectedNearWireRevalidationReceiptSha256'
$expectedFramePlanSha256 = Assert-Sha256 $ExpectedFramePlanReceiptSha256 'ExpectedFramePlanReceiptSha256'

$sessionSha256 = Get-FileSha256 $sessionPath
Assert-True ($sessionSha256 -eq $expectedSessionSha256) 'Stdio session-affinity receipt differs from the externally expected digest.'
Assert-True ((Get-FileSha256 $nearWirePath) -eq $expectedNearWireSha256) 'Near-wire revalidation receipt differs from the externally expected digest.'
Assert-True ((Get-FileSha256 $framePlanPath) -eq $expectedFramePlanSha256) 'Frame-plan receipt differs from the externally expected digest.'
Assert-True (-not [string]::Equals($childWritePath, $nearWireWritePath, [System.StringComparison]::OrdinalIgnoreCase)) 'Child and near-wire write receipt paths must differ.'
Assert-True (-not [string]::Equals($nearWireWritePath, $receiptFullPath, [System.StringComparison]::OrdinalIgnoreCase)) 'Near-wire and process-owned wrapper receipt paths must differ.'

$session = Read-StrictJsonObject $sessionPath 'stdioSessionAffinity'
Assert-True ((Get-BraintrustRequiredJsonString -Object $session -Name 'component' -FieldPath 'stdioSessionAffinity.component') -eq 'windows-mcp-stdio-session-affinity-binding') 'Unexpected stdio session-affinity component.'
Assert-True ((Get-BraintrustRequiredJsonInteger -Object $session -Name 'schemaVersion' -FieldPath 'stdioSessionAffinity.schemaVersion') -ge 1) 'Stdio session-affinity schema is unsupported.'
Assert-True ((Get-BraintrustRequiredJsonString -Object $session -Name 'expectedProtocolVersion' -FieldPath 'stdioSessionAffinity.expectedProtocolVersion') -eq $ExpectedProtocolVersion) 'Stdio session-affinity protocol version differs from write protocol.'

$sessionBoundary = Get-BraintrustRequiredJsonObject -Object $session -Name 'acceptanceBoundary' -FieldPath 'stdioSessionAffinity.acceptanceBoundary'
Assert-True (Get-BraintrustRequiredJsonBoolean -Object $sessionBoundary -Name 'stdioCatalogProcessAffinityAccepted' -FieldPath 'stdioSessionAffinity.acceptanceBoundary.stdioCatalogProcessAffinityAccepted') 'Stdio session process affinity was not accepted.'
Assert-True (-not (Get-BraintrustRequiredJsonBoolean -Object $sessionBoundary -Name 'targetStreamOwnershipByBoundProcessProven' -FieldPath 'stdioSessionAffinity.acceptanceBoundary.targetStreamOwnershipByBoundProcessProven')) 'Session-affinity evidence must not already overclaim stream ownership.'
Assert-True (-not (Get-BraintrustRequiredJsonBoolean -Object $sessionBoundary -Name 'sameTransportConnectionObjectProven' -FieldPath 'stdioSessionAffinity.acceptanceBoundary.sameTransportConnectionObjectProven')) 'Session-affinity evidence must not already overclaim transport-object identity.'

$processAffinity = Get-BraintrustRequiredJsonObject -Object $session -Name 'processAffinity' -FieldPath 'stdioSessionAffinity.processAffinity'
$expectedPid64 = Get-BraintrustRequiredJsonInteger -Object $processAffinity -Name 'processId' -FieldPath 'stdioSessionAffinity.processAffinity.processId'
Assert-True ($expectedPid64 -gt 0 -and $expectedPid64 -le [int]::MaxValue) 'Stdio session-affinity process id is invalid.'
$expectedPid = [int]$expectedPid64
$expectedStartTimeUtc = ConvertTo-UtcTimestamp (Get-BraintrustRequiredJsonTimestampString -Object $processAffinity -Name 'processStartTimeUtc' -FieldPath 'stdioSessionAffinity.processAffinity.processStartTimeUtc') 'stdioSessionAffinity.processAffinity.processStartTimeUtc'
$expectedImagePath = Get-FullPath (Get-BraintrustRequiredJsonString -Object $processAffinity -Name 'imagePath' -FieldPath 'stdioSessionAffinity.processAffinity.imagePath')
$expectedImageSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $processAffinity -Name 'imageBackingFileSha256' -FieldPath 'stdioSessionAffinity.processAffinity.imageBackingFileSha256') 'stdioSessionAffinity.processAffinity.imageBackingFileSha256'

$sessionInputs = Get-BraintrustRequiredJsonObject -Object $session -Name 'inputEvidence' -FieldPath 'stdioSessionAffinity.inputEvidence'
$spawnReceiptPath = Resolve-RecordedPath -OwnerReceiptPath $sessionPath -RecordedPath (Get-BraintrustRequiredJsonString -Object $sessionInputs -Name 'targetSpawnedProcessIdentityReceiptPath' -FieldPath 'stdioSessionAffinity.inputEvidence.targetSpawnedProcessIdentityReceiptPath')
$spawnReceiptExpectedSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $sessionInputs -Name 'targetSpawnedProcessIdentityReceiptSha256' -FieldPath 'stdioSessionAffinity.inputEvidence.targetSpawnedProcessIdentityReceiptSha256') 'stdioSessionAffinity.inputEvidence.targetSpawnedProcessIdentityReceiptSha256'
Assert-True ((Get-FileSha256 $spawnReceiptPath) -eq $spawnReceiptExpectedSha256) 'Spawned-process identity receipt changed after stdio session-affinity binding.'

$before = Get-LiveProcessIdentity -Process $TargetProcess -FieldPath 'TargetProcess'
Assert-True ($before.pid -eq $expectedPid) 'TargetProcess id differs from the stdio session process id.'
Assert-True ($before.startTimeUtc.UtcTicks -eq $expectedStartTimeUtc.UtcTicks) 'TargetProcess StartTime differs from the stdio session process lifetime.'
Assert-PathEquivalent $before.imagePath $expectedImagePath 'TargetProcess image path differs from the stdio session process image.'
Assert-True ($before.imageBackingFileSha256 -eq $expectedImageSha256) 'TargetProcess image bytes differ from the stdio session process image.'

Assert-True ($TargetProcess.StartInfo.RedirectStandardInput) 'TargetProcess was not started with redirected StandardInput.'
$ownedStream = $null
try {
    $ownedStream = $TargetProcess.StandardInput.BaseStream
} catch {
    throw "Unable to obtain StandardInput.BaseStream from the bound TargetProcess: $($_.Exception.Message)"
}
Assert-True ($null -ne $ownedStream) 'TargetProcess StandardInput.BaseStream is unavailable.'
Assert-True ($ownedStream.CanWrite) 'TargetProcess StandardInput.BaseStream is not writable.'

# Re-hash process/session evidence immediately before handing the process-owned stream to the near-wire sender.
Assert-True ((Get-FileSha256 $sessionPath) -eq $sessionSha256) 'Stdio session-affinity receipt changed before process-owned write delegation.'
Assert-True ((Get-FileSha256 $spawnReceiptPath) -eq $spawnReceiptExpectedSha256) 'Spawned-process identity receipt changed before process-owned write delegation.'
Assert-True ((Get-FileSha256 $expectedImagePath) -eq $expectedImageSha256) 'Bound process executable bytes changed before process-owned write delegation.'

& $nearWireWriteGate `
    -NearWireRevalidationReceiptPath $nearWirePath `
    -ExpectedNearWireRevalidationReceiptSha256 $expectedNearWireSha256 `
    -FramePlanReceiptPath $framePlanPath `
    -ExpectedFramePlanReceiptSha256 $expectedFramePlanSha256 `
    -TargetStream $ownedStream `
    -ChildWriteAttemptReceiptPath $childWritePath `
    -ReceiptPath $nearWireWritePath `
    -WriteTimeoutMs $WriteTimeoutMs `
    -ExpectedProtocolVersion $ExpectedProtocolVersion `
    -Transport $Transport | Out-Null

Assert-True (Test-Path -LiteralPath $childWritePath -PathType Leaf) 'Lower-level stdio write-attempt receipt was not produced.'
Assert-True (Test-Path -LiteralPath $nearWireWritePath -PathType Leaf) 'Near-wire stdio write receipt was not produced.'
$childWriteSha256 = Get-FileSha256 $childWritePath
$nearWireWriteSha256 = Get-FileSha256 $nearWireWritePath

$afterStillRunning = $false
$afterIdentityMatched = $false
try {
    $after = Get-LiveProcessIdentity -Process $TargetProcess -FieldPath 'TargetProcess post-write'
    $afterStillRunning = $true
    $afterIdentityMatched = ($after.pid -eq $expectedPid) -and ($after.startTimeUtc.UtcTicks -eq $expectedStartTimeUtc.UtcTicks) -and ([string]::Equals($after.imagePath, $expectedImagePath, [System.StringComparison]::OrdinalIgnoreCase)) -and ($after.imageBackingFileSha256 -eq $expectedImageSha256)
} catch {
    $afterStillRunning = $false
    $afterIdentityMatched = $false
}

Assert-True ((Get-FileSha256 $sessionPath) -eq $sessionSha256) 'Stdio session-affinity receipt changed during process-owned write attempt.'
Assert-True ((Get-FileSha256 $spawnReceiptPath) -eq $spawnReceiptExpectedSha256) 'Spawned-process identity receipt changed during process-owned write attempt.'
Assert-True ((Get-FileSha256 $nearWireWritePath) -eq $nearWireWriteSha256) 'Near-wire write receipt changed before process-owned receipt generation.'
Assert-True ((Get-FileSha256 $childWritePath) -eq $childWriteSha256) 'Lower-level write receipt changed before process-owned receipt generation.'

$receiptDirectory = Split-Path -Parent $receiptFullPath
if ($receiptDirectory) { New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null }
$receipt = [ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-process-owned-near-wire-stdio-write-attempt'
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    expectedProtocolVersion = $ExpectedProtocolVersion
    transport = $Transport
    transportHostBinding = [ordered]@{
        powerShellEdition = [string]$PSVersionTable.PSEdition
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        powerShellCore7OrLaterRequired = $true
        windowsPowerShell51Accepted = $false
    }
    processOwnershipBinding = [ordered]@{
        processId = $expectedPid
        processStartTimeUtc = $expectedStartTimeUtc.ToString('o')
        imagePath = $expectedImagePath
        imageBackingFileSha256 = $expectedImageSha256
        targetProcessObjectMatchedSessionAffinityBeforeWrite = $true
        standardInputWasRedirected = $true
        targetStreamDerivedFromTargetProcessStandardInputBaseStream = $true
        targetStreamSuppliedByCaller = $false
        processStillRunningAfterWriteObservation = $afterStillRunning
        processIdentityStillMatchedAfterWriteObservation = $afterIdentityMatched
    }
    sourceEvidence = [ordered]@{
        stdioSessionAffinityReceiptPath = $sessionPath
        stdioSessionAffinityReceiptSha256 = $sessionSha256
        spawnedProcessIdentityReceiptPath = $spawnReceiptPath
        spawnedProcessIdentityReceiptSha256 = $spawnReceiptExpectedSha256
        nearWireRevalidationReceiptPath = $nearWirePath
        nearWireRevalidationReceiptSha256 = $expectedNearWireSha256
        framePlanReceiptPath = $framePlanPath
        framePlanReceiptSha256 = $expectedFramePlanSha256
        nearWireWriteReceiptPath = $nearWireWritePath
        nearWireWriteReceiptSha256 = $nearWireWriteSha256
        childWriteAttemptReceiptPath = $childWritePath
        childWriteAttemptReceiptSha256 = $childWriteSha256
    }
    acceptanceBoundary = [ordered]@{
        powerShellCore7TransportHostAccepted = $true
        windowsPowerShell51TransportHostAccepted = $false
        processOwnedStreamConstructionAccepted = $true
        targetProcessObjectIdentityMatchedSessionReceiptAtWriteBoundary = $true
        targetStreamDerivedFromBoundProcessObject = $true
        arbitraryCallerSuppliedTargetStreamAccepted = $false
        namedPipePeerPidApisAcceptedAsOwnershipAuthority = $false
        kernelPipePeerIdentityProven = $false
        sameTransportConnectionObjectCryptographicallyProven = $false
        processLifetimeRaceFree = $false
        mappedImageCryptographicallyProven = $false
        downstreamPhysicalServerIdentityAccepted = $false
        generationCurrentAtActualWireSendProven = $false
        authorizationContextAccepted = $false
        humanApprovalAccepted = $false
        toolExecutionAuthorized = $false
        serverReadObserved = $false
        deliveryOutcomeKnown = $false
        semanticToolAccepted = $false
        windowsFinalStateAccepted = $false
    }
}
[System.IO.File]::WriteAllText($receiptFullPath, ($receipt | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
$receiptSha256 = Get-FileSha256 $receiptFullPath

[pscustomobject][ordered]@{
    receiptPath = $receiptFullPath
    receiptSha256 = $receiptSha256
    processId = $expectedPid
    processStartTimeUtc = $expectedStartTimeUtc.ToString('o')
    targetStreamDerivedFromTargetProcessStandardInputBaseStream = $true
    processOwnedStreamConstructionAccepted = $true
    processStillRunningAfterWriteObservation = $afterStillRunning
    processIdentityStillMatchedAfterWriteObservation = $afterIdentityMatched
    kernelPipePeerIdentityProven = $false
    downstreamPhysicalServerIdentityAccepted = $false
    generationCurrentAtActualWireSendProven = $false
    toolExecutionAuthorized = $false
    deliveryOutcomeKnown = $false
    semanticToolAccepted = $false
    windowsFinalStateAccepted = $false
}
