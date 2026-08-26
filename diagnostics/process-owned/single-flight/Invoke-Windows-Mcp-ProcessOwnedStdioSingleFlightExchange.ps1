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
    [Parameter(Mandatory = $true)][string]$ProcessOwnedWriteReceiptPath,
    [Parameter(Mandatory = $true)][string]$ResponseArtifactPath,
    [Parameter(Mandatory = $true)][string]$ResponseCaptureReceiptPath,
    [Parameter(Mandatory = $true)][string]$LeaseRootPath,
    [Parameter(Mandatory = $true)][string]$ReceiptPath,
    [ValidateRange(100, 30000)][int]$WriteTimeoutMs = 5000,
    [ValidateRange(100, 30000)][int]$ReadTimeoutMs = 5000,
    [ValidateRange(256, 10485760)][int]$MaxFrameBytes = 1048576,
    [string]$ExpectedProtocolVersion = '2026-07-28',
    [ValidateSet('stdio')][string]$Transport = 'stdio'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'MCP_STDIO_TRANSPORT_HOST_UNSUPPORTED: runtime single-flight MCP stdio exchange requires PowerShell Core 7 or later.'
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$strictHelper = Join-Path $scriptRoot 'Get-BraintrustStrictJsonScalar.ps1'
$writeGate = Join-Path $scriptRoot 'Invoke-Windows-Mcp-ProcessOwnedNearWireStdioFrameWriteAttempt.ps1'
$responseGate = Join-Path $scriptRoot 'Read-Windows-Mcp-ProcessOwnedStdioResponseArtifact.ps1'
foreach ($requiredFile in @($strictHelper, $writeGate, $responseGate)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required single-flight stdio dependency was not found: $requiredFile"
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

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
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
    Assert-True (-not $Process.HasExited) "$FieldPath process exited before the single-flight boundary."
    $imagePath = $null
    try { $imagePath = [string]$Process.Path } catch {}
    if ([string]::IsNullOrWhiteSpace($imagePath)) {
        try { $imagePath = [string]$Process.MainModule.FileName } catch {}
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($imagePath)) "$FieldPath image path could not be observed."
    $imagePath = Get-FullPath $imagePath
    Assert-True (Test-Path -LiteralPath $imagePath -PathType Leaf) "$FieldPath image path no longer exists."
    [pscustomobject][ordered]@{
        pid = [int]$Process.Id
        startTimeUtc = ([datetimeoffset]$Process.StartTime).ToUniversalTime()
        imagePath = $imagePath
        imageBackingFileSha256 = Get-FileSha256 $imagePath
    }
}

function Assert-NoReparseComponents([string]$Path, [string]$FieldPath) {
    $full = Get-FullPath $Path
    $root = [System.IO.Path]::GetPathRoot($full)
    Assert-True (-not [string]::IsNullOrWhiteSpace($root)) "$FieldPath must have a drive root."
    $remainder = $full.Substring($root.Length).Trim('\')
    $current = $root
    if ([string]::IsNullOrWhiteSpace($remainder)) { return }
    foreach ($segment in ($remainder -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            Assert-True (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "$FieldPath contains an existing reparse-point component: $current"
        }
    }
}

function Assert-LocalFixedLeaseRoot([string]$Path) {
    $full = Get-FullPath $Path
    Assert-True (-not $full.StartsWith('\\', [System.StringComparison]::Ordinal)) 'LeaseRootPath must not be a UNC path.'
    $root = [System.IO.Path]::GetPathRoot($full)
    Assert-True (-not [string]::IsNullOrWhiteSpace($root)) 'LeaseRootPath must be rooted on a local drive.'
    $drive = [System.IO.DriveInfo]::new($root)
    Assert-True ($drive.DriveType -eq [System.IO.DriveType]::Fixed) 'LeaseRootPath must be on a fixed local drive.'
    Assert-NoReparseComponents $full 'LeaseRootPath'
    New-Item -ItemType Directory -Path $full -Force | Out-Null
    Assert-NoReparseComponents $full 'LeaseRootPath'
    return $full
}

Assert-True ($env:OS -eq 'Windows_NT') 'Runtime single-flight stdio exchange only supports Windows.'
Assert-True ($ExpectedProtocolVersion -eq '2026-07-28') 'Runtime single-flight stdio exchange currently supports only MCP 2026-07-28.'
Assert-True ($Transport -eq 'stdio') 'Runtime single-flight stdio exchange currently supports only stdio.'

$sessionPath = Get-FullPath $StdioSessionAffinityReceiptPath
$nearWirePath = Get-FullPath $NearWireRevalidationReceiptPath
$framePlanPath = Get-FullPath $FramePlanReceiptPath
$childWritePath = Get-FullPath $ChildWriteAttemptReceiptPath
$nearWireWritePath = Get-FullPath $NearWireWriteReceiptPath
$processOwnedWritePath = Get-FullPath $ProcessOwnedWriteReceiptPath
$responseArtifactFullPath = Get-FullPath $ResponseArtifactPath
$responseCapturePath = Get-FullPath $ResponseCaptureReceiptPath
$receiptFullPath = Get-FullPath $ReceiptPath
$leaseRoot = Assert-LocalFixedLeaseRoot $LeaseRootPath

$expectedSessionSha256 = Assert-Sha256 $ExpectedStdioSessionAffinityReceiptSha256 'ExpectedStdioSessionAffinityReceiptSha256'
$expectedNearWireSha256 = Assert-Sha256 $ExpectedNearWireRevalidationReceiptSha256 'ExpectedNearWireRevalidationReceiptSha256'
$expectedFramePlanSha256 = Assert-Sha256 $ExpectedFramePlanReceiptSha256 'ExpectedFramePlanReceiptSha256'
$sessionSha256 = Get-FileSha256 $sessionPath
$nearWireSha256 = Get-FileSha256 $nearWirePath
$framePlanSha256 = Get-FileSha256 $framePlanPath
Assert-True ($sessionSha256 -eq $expectedSessionSha256) 'Stdio session-affinity receipt differs from the externally expected digest.'
Assert-True ($nearWireSha256 -eq $expectedNearWireSha256) 'Near-wire revalidation receipt differs from the externally expected digest.'
Assert-True ($framePlanSha256 -eq $expectedFramePlanSha256) 'Frame-plan receipt differs from the externally expected digest.'

$session = Read-StrictJsonObject $sessionPath 'stdioSessionAffinity'
Assert-True ((Get-BraintrustRequiredJsonString -Object $session -Name 'component' -FieldPath 'stdioSessionAffinity.component') -eq 'windows-mcp-stdio-session-affinity-binding') 'Unexpected stdio session-affinity component.'
$processAffinity = Get-BraintrustRequiredJsonObject -Object $session -Name 'processAffinity' -FieldPath 'stdioSessionAffinity.processAffinity'
$expectedPid64 = Get-BraintrustRequiredJsonInteger -Object $processAffinity -Name 'processId' -FieldPath 'stdioSessionAffinity.processAffinity.processId'
Assert-True ($expectedPid64 -gt 0 -and $expectedPid64 -le [int]::MaxValue) 'Stdio session-affinity process id is invalid.'
$expectedPid = [int]$expectedPid64
$expectedStartTimeUtc = ConvertTo-UtcTimestamp (Get-BraintrustRequiredJsonTimestampString -Object $processAffinity -Name 'processStartTimeUtc' -FieldPath 'stdioSessionAffinity.processAffinity.processStartTimeUtc') 'stdioSessionAffinity.processAffinity.processStartTimeUtc'
$expectedImagePath = Get-FullPath (Get-BraintrustRequiredJsonString -Object $processAffinity -Name 'imagePath' -FieldPath 'stdioSessionAffinity.processAffinity.imagePath')
$expectedImageSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $processAffinity -Name 'imageBackingFileSha256' -FieldPath 'stdioSessionAffinity.processAffinity.imageBackingFileSha256') 'stdioSessionAffinity.processAffinity.imageBackingFileSha256'
$sessionInputs = Get-BraintrustRequiredJsonObject -Object $session -Name 'inputEvidence' -FieldPath 'stdioSessionAffinity.inputEvidence'
$spawnReceiptPath = Resolve-RecordedPath $sessionPath (Get-BraintrustRequiredJsonString -Object $sessionInputs -Name 'targetSpawnedProcessIdentityReceiptPath' -FieldPath 'stdioSessionAffinity.inputEvidence.targetSpawnedProcessIdentityReceiptPath')
$spawnReceiptSha256 = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $sessionInputs -Name 'targetSpawnedProcessIdentityReceiptSha256' -FieldPath 'stdioSessionAffinity.inputEvidence.targetSpawnedProcessIdentityReceiptSha256') 'stdioSessionAffinity.inputEvidence.targetSpawnedProcessIdentityReceiptSha256'
Assert-True ((Get-FileSha256 $spawnReceiptPath) -eq $spawnReceiptSha256) 'Spawned-process identity receipt changed after stdio session-affinity binding.'

$liveBefore = Get-LiveProcessIdentity -Process $TargetProcess -FieldPath 'TargetProcess'
Assert-True ($liveBefore.pid -eq $expectedPid) 'TargetProcess id differs from the stdio session process id.'
Assert-True ($liveBefore.startTimeUtc.UtcTicks -eq $expectedStartTimeUtc.UtcTicks) 'TargetProcess StartTime differs from the stdio session process lifetime.'
Assert-PathEquivalent $liveBefore.imagePath $expectedImagePath 'TargetProcess image path differs from the stdio session process image.'
Assert-True ($liveBefore.imageBackingFileSha256 -eq $expectedImageSha256) 'TargetProcess image bytes differ from the stdio session process image.'

# The lease key is intentionally session-wide. It excludes request id, approval id,
# frame-plan digest, near-wire generation digest, and tool name so two calls on the
# same process/session always compete for the same lease slot.
$separator = [char]31
$keyMaterial = [string]::Join([string]$separator, @(
    $Transport,
    $ExpectedProtocolVersion,
    [string]$expectedPid,
    [string]$expectedStartTimeUtc.UtcTicks,
    $expectedImagePath.ToLowerInvariant(),
    $expectedImageSha256
))
$sessionKeySha256 = Get-BytesSha256 ([System.Text.UTF8Encoding]::new($false).GetBytes($keyMaterial))
$leasePath = Join-Path $leaseRoot ($sessionKeySha256 + '.stdio-single-flight.json')
Assert-NoReparseComponents $leasePath 'Single-flight lease path'

$leaseRecord = [ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-stdio-single-flight-lease'
    acquiredAtUtc = [datetime]::UtcNow.ToString('o')
    expectedProtocolVersion = $ExpectedProtocolVersion
    transport = $Transport
    sessionKeySha256 = $sessionKeySha256
    processIdentity = [ordered]@{
        processId = $expectedPid
        processStartTimeUtc = $expectedStartTimeUtc.ToString('o')
        imagePath = $expectedImagePath
        imageBackingFileSha256 = $expectedImageSha256
    }
    inputEvidence = [ordered]@{
        stdioSessionAffinityReceiptPath = $sessionPath
        stdioSessionAffinityReceiptSha256 = $sessionSha256
        targetSpawnedProcessIdentityReceiptPath = $spawnReceiptPath
        targetSpawnedProcessIdentityReceiptSha256 = $spawnReceiptSha256
        nearWireRevalidationReceiptPath = $nearWirePath
        nearWireRevalidationReceiptSha256 = $nearWireSha256
        framePlanReceiptPath = $framePlanPath
        framePlanReceiptSha256 = $framePlanSha256
    }
    policy = [ordered]@{
        oneInFlightCallPerProcessSession = $true
        requestSpecificLeaseKey = $false
        leaseRetainedOnFailure = $true
        automaticRetryAfterUnknownDeliveryAccepted = $false
    }
}
$leaseBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($leaseRecord | ConvertTo-Json -Depth 30))
$leaseStream = $null
try {
    $leaseStream = [System.IO.File]::Open($leasePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $leaseStream.Write($leaseBytes, 0, $leaseBytes.Length)
    # Request an OS/intermediate-buffer flush before the lease becomes effectuation authority.
    # This narrows abrupt-termination loss risk but is not a power-loss or exactly-once proof.
    $leaseStream.Flush($true)
} catch [System.IO.IOException] {
    throw "MCP_STDIO_SINGLE_FLIGHT_BUSY_OR_STALE: a lease already exists for process/session $sessionKeySha256; do not retry automatically because delivery state may be unknown."
} finally {
    if ($null -ne $leaseStream) { $leaseStream.Dispose() }
}
$leaseSha256 = Get-FileSha256 $leasePath
Assert-True ($leaseSha256 -eq (Get-BytesSha256 $leaseBytes)) 'Persisted single-flight lease bytes differ from the acquired lease record.'

# From this point onward there is intentionally no finally-block cleanup. Any
# exception leaves the session lease in place and forces a fresh session or an
# explicit recovery decision rather than an automatic replay.
& $writeGate `
    -TargetProcess $TargetProcess `
    -StdioSessionAffinityReceiptPath $sessionPath `
    -ExpectedStdioSessionAffinityReceiptSha256 $sessionSha256 `
    -NearWireRevalidationReceiptPath $nearWirePath `
    -ExpectedNearWireRevalidationReceiptSha256 $nearWireSha256 `
    -FramePlanReceiptPath $framePlanPath `
    -ExpectedFramePlanReceiptSha256 $framePlanSha256 `
    -ChildWriteAttemptReceiptPath $childWritePath `
    -NearWireWriteReceiptPath $nearWireWritePath `
    -ReceiptPath $processOwnedWritePath `
    -WriteTimeoutMs $WriteTimeoutMs `
    -ExpectedProtocolVersion $ExpectedProtocolVersion `
    -Transport $Transport | Out-Null

Assert-True (Test-Path -LiteralPath $processOwnedWritePath -PathType Leaf) 'Process-owned write receipt was not produced while the single-flight lease was held.'
$processOwnedWriteSha256 = Get-FileSha256 $processOwnedWritePath

& $responseGate `
    -TargetProcess $TargetProcess `
    -StdioSessionAffinityReceiptPath $sessionPath `
    -ExpectedStdioSessionAffinityReceiptSha256 $sessionSha256 `
    -FramePlanReceiptPath $framePlanPath `
    -ExpectedFramePlanReceiptSha256 $framePlanSha256 `
    -ResponseArtifactPath $responseArtifactFullPath `
    -ReceiptPath $responseCapturePath `
    -ReadTimeoutMs $ReadTimeoutMs `
    -MaxFrameBytes $MaxFrameBytes `
    -ExpectedProtocolVersion $ExpectedProtocolVersion `
    -Transport $Transport | Out-Null

Assert-True (Test-Path -LiteralPath $responseCapturePath -PathType Leaf) 'Process-owned response-capture receipt was not produced while the single-flight lease was held.'
$responseCaptureSha256 = Get-FileSha256 $responseCapturePath
$responseCapture = Read-StrictJsonObject $responseCapturePath 'responseCapture'
Assert-True ((Get-BraintrustRequiredJsonString -Object $responseCapture -Name 'component' -FieldPath 'responseCapture.component') -eq 'windows-mcp-process-owned-stdio-response-capture') 'Unexpected response-capture component.'
$responseBinding = Get-BraintrustRequiredJsonObject -Object $responseCapture -Name 'requestResponseBinding' -FieldPath 'responseCapture.requestResponseBinding'
$requestId = Get-BraintrustRequiredJsonString -Object $responseBinding -Name 'requestId' -FieldPath 'responseCapture.requestResponseBinding.requestId'
$responseId = Get-BraintrustRequiredJsonString -Object $responseBinding -Name 'responseId' -FieldPath 'responseCapture.requestResponseBinding.responseId'
Assert-True ([string]::Equals($requestId, $responseId, [System.StringComparison]::Ordinal)) 'Single-flight response id does not match the request id.'

Assert-True ((Get-FileSha256 $leasePath) -eq $leaseSha256) 'Single-flight lease changed while the request was in flight.'
Assert-True ((Get-FileSha256 $sessionPath) -eq $sessionSha256) 'Stdio session-affinity receipt changed while the request was in flight.'
Assert-True ((Get-FileSha256 $spawnReceiptPath) -eq $spawnReceiptSha256) 'Spawned-process identity receipt changed while the request was in flight.'
Assert-True ((Get-FileSha256 $nearWirePath) -eq $nearWireSha256) 'Near-wire generation evidence changed while the request was in flight.'
Assert-True ((Get-FileSha256 $framePlanPath) -eq $framePlanSha256) 'Frame-plan evidence changed while the request was in flight.'
Assert-True ((Get-FileSha256 $processOwnedWritePath) -eq $processOwnedWriteSha256) 'Process-owned write receipt changed before lease release.'
Assert-True ((Get-FileSha256 $responseCapturePath) -eq $responseCaptureSha256) 'Response-capture receipt changed before lease release.'
$liveAfter = Get-LiveProcessIdentity -Process $TargetProcess -FieldPath 'TargetProcess post-response'
Assert-True ($liveAfter.pid -eq $expectedPid) 'TargetProcess id changed before lease release.'
Assert-True ($liveAfter.startTimeUtc.UtcTicks -eq $expectedStartTimeUtc.UtcTicks) 'TargetProcess lifetime changed before lease release.'
Assert-PathEquivalent $liveAfter.imagePath $expectedImagePath 'TargetProcess image path changed before lease release.'
Assert-True ($liveAfter.imageBackingFileSha256 -eq $expectedImageSha256) 'TargetProcess image bytes changed before lease release.'

# Release only after the matching response has been captured and all load-bearing
# evidence has been re-read. If removal fails, no accepted wrapper receipt is emitted.
Remove-Item -LiteralPath $leasePath -Force -ErrorAction Stop
Assert-True (-not (Test-Path -LiteralPath $leasePath)) 'Single-flight lease still exists after a successful matching response.'

$receiptDirectory = Split-Path -Parent $receiptFullPath
if ($receiptDirectory) { New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null }
$receipt = [ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-stdio-single-flight-exchange'
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    expectedProtocolVersion = $ExpectedProtocolVersion
    transport = $Transport
    sessionBinding = [ordered]@{
        sessionKeySha256 = $sessionKeySha256
        processId = $expectedPid
        processStartTimeUtc = $expectedStartTimeUtc.ToString('o')
        imagePath = $expectedImagePath
        imageBackingFileSha256 = $expectedImageSha256
    }
    requestResponseBinding = [ordered]@{
        requestId = $requestId
        responseId = $responseId
        exactMatchingResponseCaptured = $true
    }
    leaseEvidence = [ordered]@{
        leasePath = $leasePath
        acquiredLeaseSha256 = $leaseSha256
        leaseReleasedAfterMatchingResponse = $true
        leaseRetainedOnFailureByDesign = $true
        requestSpecificLeaseKey = $false
    }
    sourceEvidence = [ordered]@{
        stdioSessionAffinityReceiptPath = $sessionPath
        stdioSessionAffinityReceiptSha256 = $sessionSha256
        targetSpawnedProcessIdentityReceiptPath = $spawnReceiptPath
        targetSpawnedProcessIdentityReceiptSha256 = $spawnReceiptSha256
        nearWireRevalidationReceiptPath = $nearWirePath
        nearWireRevalidationReceiptSha256 = $nearWireSha256
        framePlanReceiptPath = $framePlanPath
        framePlanReceiptSha256 = $framePlanSha256
        processOwnedWriteReceiptPath = $processOwnedWritePath
        processOwnedWriteReceiptSha256 = $processOwnedWriteSha256
        responseCaptureReceiptPath = $responseCapturePath
        responseCaptureReceiptSha256 = $responseCaptureSha256
        responseArtifactPath = $responseArtifactFullPath
        responseArtifactSha256 = Get-FileSha256 $responseArtifactFullPath
    }
    acceptanceBoundary = [ordered]@{
        runtimeSingleFlightLeaseImplemented = $true
        singleFlightLeaseHeldAcrossWriteAndMatchingResponseCapture = $true
        concurrentSameSessionCallBlockedWhileLeaseExists = $true
        leaseReleasedOnlyAfterMatchingResponse = $true
        runtimeSingleFlightLeaseConsumedByCanonicalExchangeWrapper = $true
        runtimeSingleFlightLeaseConsumedByProductionOrchestrator = $false
        outOfOrderResponseDemultiplexerAccepted = $false
        responseBufferByRequestIdAccepted = $false
        automaticRetryAfterUnknownDeliveryAccepted = $false
        crashRecoveryReplayAccepted = $false
        powerLossDurabilityAccepted = $false
        runtimeBypassCryptographicallyPrevented = $false
        exactlyOnceToolSideEffectProven = $false
        downstreamPhysicalServerIdentityAccepted = $false
        toolExecutionAuthorized = $false
        semanticToolAccepted = $false
        windowsFinalStateAccepted = $false
    }
}
[System.IO.File]::WriteAllText($receiptFullPath, ($receipt | ConvertTo-Json -Depth 40), [System.Text.UTF8Encoding]::new($false))
$receipt