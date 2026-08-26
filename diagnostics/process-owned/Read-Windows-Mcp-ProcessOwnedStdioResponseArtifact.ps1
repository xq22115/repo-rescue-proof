param(
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$TargetProcess,
    [Parameter(Mandatory = $true)][string]$StdioSessionAffinityReceiptPath,
    [Parameter(Mandatory = $true)][string]$ExpectedStdioSessionAffinityReceiptSha256,
    [Parameter(Mandatory = $true)][string]$FramePlanReceiptPath,
    [Parameter(Mandatory = $true)][string]$ExpectedFramePlanReceiptSha256,
    [Parameter(Mandatory = $true)][string]$ResponseArtifactPath,
    [Parameter(Mandatory = $true)][string]$ReceiptPath,
    [ValidateRange(100, 30000)][int]$ReadTimeoutMs = 5000,
    [ValidateRange(256, 10485760)][int]$MaxFrameBytes = 1048576,
    [string]$ExpectedProtocolVersion = '2026-07-28',
    [ValidateSet('stdio')][string]$Transport = 'stdio'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'MCP_STDIO_TRANSPORT_HOST_UNSUPPORTED: process-owned MCP stdio response capture requires PowerShell Core 7 or later; Windows PowerShell 5.1 is not accepted as an exact-byte stdio broker.'
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$strictHelper = Join-Path $scriptRoot 'Get-BraintrustStrictJsonScalar.ps1'
if (-not (Test-Path -LiteralPath $strictHelper -PathType Leaf)) {
    throw "Required response-capture dependency was not found: $strictHelper"
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
    Assert-True (-not $Process.HasExited) "$FieldPath process exited before the stdio response-capture boundary."
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

Assert-True ($env:OS -eq 'Windows_NT') 'Process-owned stdio response capture only supports Windows.'
Assert-True ($ExpectedProtocolVersion -eq '2026-07-28') 'Process-owned stdio response capture currently supports only MCP 2026-07-28.'
Assert-True ($Transport -eq 'stdio') 'Process-owned stdio response capture currently supports only stdio.'

$sessionPath = Get-FullPath $StdioSessionAffinityReceiptPath
$framePlanPath = Get-FullPath $FramePlanReceiptPath
$responseArtifactFullPath = Get-FullPath $ResponseArtifactPath
$receiptFullPath = Get-FullPath $ReceiptPath
Assert-True (-not [string]::Equals($responseArtifactFullPath, $receiptFullPath, [System.StringComparison]::OrdinalIgnoreCase)) 'Response artifact and response-capture receipt paths must differ.'
$expectedSessionSha256 = Assert-Sha256 $ExpectedStdioSessionAffinityReceiptSha256 'ExpectedStdioSessionAffinityReceiptSha256'
$expectedFramePlanSha256 = Assert-Sha256 $ExpectedFramePlanReceiptSha256 'ExpectedFramePlanReceiptSha256'
$sessionSha256 = Get-FileSha256 $sessionPath
$framePlanSha256 = Get-FileSha256 $framePlanPath
Assert-True ($sessionSha256 -eq $expectedSessionSha256) 'Stdio session-affinity receipt differs from the externally expected digest.'
Assert-True ($framePlanSha256 -eq $expectedFramePlanSha256) 'Frame-plan receipt differs from the externally expected digest.'

$session = Read-StrictJsonObject $sessionPath 'stdioSessionAffinity'
Assert-True ((Get-BraintrustRequiredJsonString -Object $session -Name 'component' -FieldPath 'stdioSessionAffinity.component') -eq 'windows-mcp-stdio-session-affinity-binding') 'Unexpected stdio session-affinity component.'
Assert-True ((Get-BraintrustRequiredJsonInteger -Object $session -Name 'schemaVersion' -FieldPath 'stdioSessionAffinity.schemaVersion') -ge 1) 'Stdio session-affinity schema is unsupported.'
Assert-True ((Get-BraintrustRequiredJsonString -Object $session -Name 'expectedProtocolVersion' -FieldPath 'stdioSessionAffinity.expectedProtocolVersion') -eq $ExpectedProtocolVersion) 'Stdio session-affinity protocol differs from response capture.'
$sessionBoundary = Get-BraintrustRequiredJsonObject -Object $session -Name 'acceptanceBoundary' -FieldPath 'stdioSessionAffinity.acceptanceBoundary'
Assert-True (Get-BraintrustRequiredJsonBoolean -Object $sessionBoundary -Name 'stdioCatalogProcessAffinityAccepted' -FieldPath 'stdioSessionAffinity.acceptanceBoundary.stdioCatalogProcessAffinityAccepted') 'Stdio session process affinity was not accepted.'

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

$framePlan = Read-StrictJsonObject $framePlanPath 'framePlan'
Assert-True ((Get-BraintrustRequiredJsonString -Object $framePlan -Name 'component' -FieldPath 'framePlan.component') -eq 'windows-mcp-multi-server-stdio-tool-call-frame-plan') 'Unexpected frame-plan component.'
Assert-True ((Get-BraintrustRequiredJsonString -Object $framePlan -Name 'expectedProtocolVersion' -FieldPath 'framePlan.expectedProtocolVersion') -eq $ExpectedProtocolVersion) 'Frame-plan protocol differs from response capture.'
Assert-True ((Get-BraintrustRequiredJsonString -Object $framePlan -Name 'transport' -FieldPath 'framePlan.transport') -eq $Transport) 'Frame-plan transport differs from response capture.'
$frameRequest = Get-BraintrustRequiredJsonObject -Object $framePlan -Name 'requestBinding' -FieldPath 'framePlan.requestBinding'
$requestId = Get-BraintrustRequiredJsonString -Object $frameRequest -Name 'requestId' -FieldPath 'framePlan.requestBinding.requestId'

$before = Get-LiveProcessIdentity -Process $TargetProcess -FieldPath 'TargetProcess'
Assert-True ($before.pid -eq $expectedPid) 'TargetProcess id differs from the stdio session process id.'
Assert-True ($before.startTimeUtc.UtcTicks -eq $expectedStartTimeUtc.UtcTicks) 'TargetProcess StartTime differs from the stdio session process lifetime.'
Assert-PathEquivalent $before.imagePath $expectedImagePath 'TargetProcess image path differs from the stdio session process image.'
Assert-True ($before.imageBackingFileSha256 -eq $expectedImageSha256) 'TargetProcess image bytes differ from the stdio session process image.'
Assert-True ($TargetProcess.StartInfo.RedirectStandardOutput) 'TargetProcess was not started with redirected StandardOutput.'
$ownedStream = $TargetProcess.StandardOutput.BaseStream
Assert-True ($null -ne $ownedStream -and $ownedStream.CanRead) 'TargetProcess StandardOutput.BaseStream is unavailable or unreadable.'

Assert-True ((Get-FileSha256 $sessionPath) -eq $sessionSha256) 'Stdio session-affinity receipt changed before response capture.'
Assert-True ((Get-FileSha256 $spawnReceiptPath) -eq $spawnReceiptSha256) 'Spawned-process identity receipt changed before response capture.'
Assert-True ((Get-FileSha256 $framePlanPath) -eq $framePlanSha256) 'Frame-plan receipt changed before response capture.'
Assert-True ((Get-FileSha256 $expectedImagePath) -eq $expectedImageSha256) 'Bound process executable bytes changed before response capture.'

$buffer = New-Object System.Collections.Generic.List[byte]
$cts = [System.Threading.CancellationTokenSource]::new($ReadTimeoutMs)
try {
    [byte[]]$one = New-Object byte[] 1
    while ($true) {
        $count = 0
        try {
            $count = $ownedStream.ReadAsync($one, 0, 1, $cts.Token).GetAwaiter().GetResult()
        } catch {
            if ($cts.IsCancellationRequested) { throw "Timed out waiting for a complete stdio JSON-RPC response after ${ReadTimeoutMs}ms." }
            throw
        }
        Assert-True ($count -eq 1) 'Stdio response stream ended before an LF-delimited JSON-RPC message was complete.'
        $value = [byte]$one[0]
        if ($value -eq 10) { break }
        Assert-True ($value -ne 13) 'Stdio response contained a carriage-return byte; exact MCP framing requires LF-only delimiting.'
        $buffer.Add($value)
        Assert-True ($buffer.Count -le $MaxFrameBytes) "Stdio response exceeded the configured ${MaxFrameBytes}-byte bound."
    }
} finally {
    $cts.Dispose()
}

[byte[]]$bodyBytes = $buffer.ToArray()
Assert-True ($bodyBytes.Length -gt 0) 'Stdio response body was empty.'
if ($bodyBytes.Length -ge 3) {
    Assert-True (-not ($bodyBytes[0] -eq 0xEF -and $bodyBytes[1] -eq 0xBB -and $bodyBytes[2] -eq 0xBF)) 'Stdio response must not start with a UTF-8 BOM.'
}
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
try { $responseText = $utf8.GetString($bodyBytes) }
catch { throw "Stdio response was not valid UTF-8: $($_.Exception.Message)" }
try { $responseObject = Assert-BraintrustJsonObjectValue -Value ($responseText | ConvertFrom-Json -ErrorAction Stop) -FieldPath 'stdioResponse' }
catch { throw "Stdio response was not a valid JSON object: $($_.Exception.Message)" }
Assert-True ((Get-BraintrustRequiredJsonString -Object $responseObject -Name 'jsonrpc' -FieldPath 'stdioResponse.jsonrpc') -eq '2.0') 'Stdio response must be JSON-RPC 2.0.'
$responseId = Get-BraintrustRequiredJsonString -Object $responseObject -Name 'id' -FieldPath 'stdioResponse.id'
Assert-True ([string]::Equals($responseId, $requestId, [System.StringComparison]::Ordinal)) 'Stdio response id differs from the frame-plan request id.'
$resultProperty = Get-BraintrustJsonProperty -Object $responseObject -Name 'result'
$errorProperty = Get-BraintrustJsonProperty -Object $responseObject -Name 'error'
Assert-True (($null -ne $resultProperty) -xor ($null -ne $errorProperty)) 'Stdio response must contain exactly one of result or error.'
if ($null -ne $resultProperty) { [void](Assert-BraintrustJsonObjectValue -Value $resultProperty.Value -FieldPath 'stdioResponse.result') }
if ($null -ne $errorProperty) { [void](Assert-BraintrustJsonObjectValue -Value $errorProperty.Value -FieldPath 'stdioResponse.error') }

$responseDirectory = Split-Path -Parent $responseArtifactFullPath
if ($responseDirectory) { New-Item -ItemType Directory -Path $responseDirectory -Force | Out-Null }
[System.IO.File]::WriteAllBytes($responseArtifactFullPath, $bodyBytes)
$responseArtifactSha256 = Get-FileSha256 $responseArtifactFullPath
Assert-True ($responseArtifactSha256 -eq (Get-BytesSha256 $bodyBytes)) 'Persisted response artifact bytes differ from the captured response body.'
[byte[]]$frameBytes = New-Object byte[] ($bodyBytes.Length + 1)
[System.Buffer]::BlockCopy($bodyBytes, 0, $frameBytes, 0, $bodyBytes.Length)
$frameBytes[$frameBytes.Length - 1] = 0x0A
$responseFrameSha256 = Get-BytesSha256 $frameBytes

$afterStillRunning = $false
$afterIdentityMatched = $false
try {
    $after = Get-LiveProcessIdentity -Process $TargetProcess -FieldPath 'TargetProcess post-response'
    $afterStillRunning = $true
    $afterIdentityMatched = ($after.pid -eq $expectedPid) -and ($after.startTimeUtc.UtcTicks -eq $expectedStartTimeUtc.UtcTicks) -and ([string]::Equals($after.imagePath, $expectedImagePath, [System.StringComparison]::OrdinalIgnoreCase)) -and ($after.imageBackingFileSha256 -eq $expectedImageSha256)
} catch {}

Assert-True ((Get-FileSha256 $sessionPath) -eq $sessionSha256) 'Stdio session-affinity receipt changed during response capture.'
Assert-True ((Get-FileSha256 $spawnReceiptPath) -eq $spawnReceiptSha256) 'Spawned-process identity receipt changed during response capture.'
Assert-True ((Get-FileSha256 $framePlanPath) -eq $framePlanSha256) 'Frame-plan receipt changed during response capture.'
Assert-True ((Get-FileSha256 $responseArtifactFullPath) -eq $responseArtifactSha256) 'Response artifact changed before response-capture receipt generation.'

$receiptDirectory = Split-Path -Parent $receiptFullPath
if ($receiptDirectory) { New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null }
$receipt = [ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-process-owned-stdio-response-capture'
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    expectedProtocolVersion = $ExpectedProtocolVersion
    transport = $Transport
    transportHostBinding = [ordered]@{
        powerShellEdition = [string]$PSVersionTable.PSEdition
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        powerShellCore7TransportHostAccepted = $true
        windowsPowerShell51TransportHostAccepted = $false
    }
    processBinding = [ordered]@{
        processId = $expectedPid
        processStartTimeUtc = $expectedStartTimeUtc.ToString('o')
        imagePath = $expectedImagePath
        imageBackingFileSha256 = $expectedImageSha256
        processStillRunningAfterResponseCapture = $afterStillRunning
        processIdentityStillMatchedAfterResponseCapture = $afterIdentityMatched
    }
    requestResponseBinding = [ordered]@{
        requestId = $requestId
        responseId = $responseId
        responseKind = $(if ($null -ne $resultProperty) { 'result' } else { 'error' })
        responseBodyUtf8ByteLength = $bodyBytes.Length
        responseArtifactSha256 = $responseArtifactSha256
        responseFrameSha256 = $responseFrameSha256
        responseFrameByteLength = $frameBytes.Length
    }
    sourceEvidence = [ordered]@{
        stdioSessionAffinityReceiptPath = $sessionPath
        stdioSessionAffinityReceiptSha256 = $sessionSha256
        targetSpawnedProcessIdentityReceiptPath = $spawnReceiptPath
        targetSpawnedProcessIdentityReceiptSha256 = $spawnReceiptSha256
        framePlanReceiptPath = $framePlanPath
        framePlanReceiptSha256 = $framePlanSha256
        responseArtifactPath = $responseArtifactFullPath
        responseArtifactSha256 = $responseArtifactSha256
    }
    acceptanceBoundary = [ordered]@{
        processOwnedResponseStreamConstructionAccepted = $true
        responseFrameObservedFromBoundProcessStandardOutput = $true
        responseArtifactExactBytesAccepted = $true
        responseIdMatchesRequestAccepted = $true
        responseOriginBoundToProcessObjectConstruction = $true
        kernelPipePeerIdentityProven = $false
        sameTransportConnectionObjectCryptographicallyProven = $false
        responseOriginAuthenticated = $false
        requestDeliveryToServerCryptographicallyProven = $false
        downstreamPhysicalServerIdentityAccepted = $false
        responseSchemaValidationAccepted = $false
        semanticToolAccepted = $false
        windowsFinalStateAccepted = $false
        processLifetimeRaceFree = $false
    }
}
[System.IO.File]::WriteAllText($receiptFullPath, ($receipt | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
$receipt
