param(
    [Parameter(Mandatory = $true)][string]$ShellLabel,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exchange = Join-Path $root 'single-flight\Invoke-Windows-Mcp-ProcessOwnedStdioSingleFlightExchange.ps1'

function Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Bytes-Sha([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}
function Image([Diagnostics.Process]$Process) {
    $path = $null
    try { $path = [string]$Process.Path } catch {}
    if ([string]::IsNullOrWhiteSpace($path)) { $path = [string]$Process.MainModule.FileName }
    [IO.Path]::GetFullPath($path)
}
function Write-Json([string]$Path, [object]$Value) {
    $full = [IO.Path]::GetFullPath($Path)
    $dir = Split-Path -Parent $full
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($full, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
}

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    $started = [datetime]::UtcNow
    $rejected = $false
    $reason = ''
    try {
        & $exchange `
            -TargetProcess (Get-Process -Id $PID) `
            -StdioSessionAffinityReceiptPath (Join-Path $env:RUNNER_TEMP 'single-flight-absent-session.json') `
            -ExpectedStdioSessionAffinityReceiptSha256 ('00' * 32) `
            -NearWireRevalidationReceiptPath (Join-Path $env:RUNNER_TEMP 'single-flight-absent-near.json') `
            -ExpectedNearWireRevalidationReceiptSha256 ('00' * 32) `
            -FramePlanReceiptPath (Join-Path $env:RUNNER_TEMP 'single-flight-absent-frame.json') `
            -ExpectedFramePlanReceiptSha256 ('00' * 32) `
            -ChildWriteAttemptReceiptPath (Join-Path $env:RUNNER_TEMP 'single-flight-must-not-write-child.json') `
            -NearWireWriteReceiptPath (Join-Path $env:RUNNER_TEMP 'single-flight-must-not-write-near.json') `
            -ProcessOwnedWriteReceiptPath (Join-Path $env:RUNNER_TEMP 'single-flight-must-not-write-process.json') `
            -ResponseArtifactPath (Join-Path $env:RUNNER_TEMP 'single-flight-must-not-write-response.json') `
            -ResponseCaptureReceiptPath (Join-Path $env:RUNNER_TEMP 'single-flight-must-not-write-capture.json') `
            -LeaseRootPath (Join-Path $env:RUNNER_TEMP 'single-flight-must-not-create-lease') `
            -ReceiptPath (Join-Path $env:RUNNER_TEMP 'single-flight-must-not-write-receipt.json') | Out-Null
    } catch {
        $reason = $_.Exception.Message
        if ($reason -like 'MCP_STDIO_TRANSPORT_HOST_UNSUPPORTED:*') { $rejected = $true }
    }
    $elapsedMs = [int](([datetime]::UtcNow - $started).TotalMilliseconds)
    if (-not $rejected) { throw "Windows PowerShell 5.1 was not rejected by exact single-flight exchange: $reason" }
    if ($elapsedMs -gt 10000) { throw "Windows PowerShell 5.1 single-flight rejection was not fail-fast: ${elapsedMs}ms" }
    Write-Json $OutputPath ([ordered]@{
        schemaVersion = 1
        component = 'public-windows-stdio-single-flight-lease-canary'
        diagnosticOnly = $true
        shellLabel = $ShellLabel
        powerShellEdition = $PSVersionTable.PSEdition
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        exactPrivateSingleFlightBlob = '36cd9a2f93bfd0012e799b6792effd0dc81e625d'
        unsupportedTransportHost = [ordered]@{
            rejectionObserved = $true
            rejectionReason = $reason
            rejectionElapsedMilliseconds = $elapsedMs
        }
        acceptanceBoundary = [ordered]@{
            exactPrivateSingleFlightBytesExercised = $true
            windowsPowerShell51FailFastTransportVetoAccepted = $true
            runtimeSingleFlightContentionNativeAccepted = $false
            failureLeaseRetentionNativeAccepted = $false
            automaticRetryAfterUnknownDeliveryAccepted = $false
            crashRecoveryReplayAccepted = $false
            exactlyOnceToolSideEffectProven = $false
        }
    })
    return
}

$work = Join-Path $env:RUNNER_TEMP ('stdio-single-flight-canary-' + [guid]::NewGuid().ToString('N'))
$leaseRoot = Join-Path $work 'leases'
New-Item -ItemType Directory -Force -Path $work, $leaseRoot | Out-Null
$process = Get-Process -Id $PID
$imagePath = Image $process
$imageSha = Sha $imagePath
$startTime = ([datetimeoffset]$process.StartTime).ToUniversalTime()

$spawnPath = Join-Path $work 'spawn.json'
Write-Json $spawnPath ([ordered]@{
    component = 'diagnostic-spawned-process'
    processId = [int]$process.Id
    processStartTimeUtc = $startTime.ToString('o')
    imagePath = $imagePath
    imageBackingFileSha256 = $imageSha
})
$spawnSha = Sha $spawnPath

$sessionPath = Join-Path $work 'session.json'
Write-Json $sessionPath ([ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-stdio-session-affinity-binding'
    processAffinity = [ordered]@{
        processId = [int]$process.Id
        processStartTimeUtc = $startTime.ToString('o')
        imagePath = $imagePath
        imageBackingFileSha256 = $imageSha
    }
    inputEvidence = [ordered]@{
        targetSpawnedProcessIdentityReceiptPath = $spawnPath
        targetSpawnedProcessIdentityReceiptSha256 = $spawnSha
    }
})
$sessionSha = Sha $sessionPath

$separator = [char]31
$keyMaterial = [string]::Join([string]$separator, @(
    'stdio',
    '2026-07-28',
    [string]$process.Id,
    [string]$startTime.UtcTicks,
    $imagePath.ToLowerInvariant(),
    $imageSha
))
$sessionKeySha = Bytes-Sha ([Text.UTF8Encoding]::new($false).GetBytes($keyMaterial))
$leasePath = Join-Path $leaseRoot ($sessionKeySha + '.stdio-single-flight.json')

function New-InputSet([string]$Tag, [string]$RequestId) {
    $dir = Join-Path $work $Tag
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $near = Join-Path $dir 'near.json'
    $frame = Join-Path $dir 'frame.json'
    Write-Json $near ([ordered]@{ component = 'diagnostic-near-wire'; tag = $Tag })
    Write-Json $frame ([ordered]@{ requestBinding = [ordered]@{ requestId = $RequestId } })
    return [ordered]@{
        TargetProcess = $process
        StdioSessionAffinityReceiptPath = $sessionPath
        ExpectedStdioSessionAffinityReceiptSha256 = $sessionSha
        NearWireRevalidationReceiptPath = $near
        ExpectedNearWireRevalidationReceiptSha256 = (Sha $near)
        FramePlanReceiptPath = $frame
        ExpectedFramePlanReceiptSha256 = (Sha $frame)
        ChildWriteAttemptReceiptPath = (Join-Path $dir 'child-write.json')
        NearWireWriteReceiptPath = (Join-Path $dir 'near-write.json')
        ProcessOwnedWriteReceiptPath = (Join-Path $dir 'process-write.json')
        ResponseArtifactPath = (Join-Path $dir 'response.json')
        ResponseCaptureReceiptPath = (Join-Path $dir 'response-capture.json')
        LeaseRootPath = $leaseRoot
        ReceiptPath = (Join-Path $dir 'exchange.json')
        WriteTimeoutMs = 5000
        ReadTimeoutMs = 5000
        MaxFrameBytes = 1048576
        ExpectedProtocolVersion = '2026-07-28'
        Transport = 'stdio'
    }
}

function Invoke-Exchange([hashtable]$Inputs) {
    & $exchange @Inputs | Out-Null
    if (-not (Test-Path -LiteralPath $Inputs.ReceiptPath -PathType Leaf)) {
        throw "Single-flight exchange did not produce receipt: $($Inputs.ReceiptPath)"
    }
    return ((Get-Content -LiteralPath $Inputs.ReceiptPath -Raw) | ConvertFrom-Json -ErrorAction Stop)
}

$success1 = New-InputSet 'success-1' 'single-flight-success-1'
$successReceipt1 = Invoke-Exchange $success1
if (-not $successReceipt1.leaseEvidence.leaseReleasedAfterMatchingResponse) { throw 'First successful exchange did not release its lease.' }
if (Test-Path -LiteralPath $leasePath) { throw 'Lease remained after first successful exchange.' }

$success2 = New-InputSet 'success-2' 'single-flight-success-2'
$successReceipt2 = Invoke-Exchange $success2
if (-not $successReceipt2.leaseEvidence.leaseReleasedAfterMatchingResponse) { throw 'Second sequential exchange did not release its lease.' }
if (Test-Path -LiteralPath $leasePath) { throw 'Lease remained after second sequential exchange.' }

# Deterministic overlapping contention: keep the winner inside the write stub long enough
# for a second caller on the same PID/StartTime/image identity to observe the lease.
$winner = New-InputSet 'winner' 'single-flight-winner'
$loser = New-InputSet 'loser' 'single-flight-loser'
$env:BRAINTRUST_SINGLE_FLIGHT_DIAGNOSTIC_HOLD_MS = '1500'
$ps = [PowerShell]::Create()
try {
    [void]$ps.AddCommand($exchange)
    foreach ($entry in $winner.GetEnumerator()) { [void]$ps.AddParameter($entry.Key, $entry.Value) }
    $async = $ps.BeginInvoke()
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) {
        if ([datetime]::UtcNow -gt $deadline) { throw 'Winner did not acquire the single-flight lease within 5 seconds.' }
        Start-Sleep -Milliseconds 25
    }

    $busyRejected = $false
    $busyReason = ''
    $busyStarted = [datetime]::UtcNow
    try {
        & $exchange @loser | Out-Null
    } catch {
        $busyReason = $_.Exception.Message
        if ($busyReason -like 'MCP_STDIO_SINGLE_FLIGHT_BUSY_OR_STALE:*') { $busyRejected = $true }
    }
    $busyElapsedMs = [int](([datetime]::UtcNow - $busyStarted).TotalMilliseconds)
    if (-not $busyRejected) { throw "Second same-session caller was not rejected while lease existed: $busyReason" }
    if ($busyElapsedMs -gt 10000) { throw "Busy single-flight rejection was not prompt: ${busyElapsedMs}ms" }

    [void]$ps.EndInvoke($async)
    if ($ps.Streams.Error.Count -gt 0) { throw $ps.Streams.Error[0].Exception }
    if (-not (Test-Path -LiteralPath $winner.ReceiptPath -PathType Leaf)) { throw 'Winner did not complete after contention test.' }
    if (Test-Path -LiteralPath $leasePath) { throw 'Winner did not release lease after matching diagnostic response.' }
} finally {
    $ps.Dispose()
    Remove-Item Env:BRAINTRUST_SINGLE_FLIGHT_DIAGNOSTIC_HOLD_MS -ErrorAction SilentlyContinue
}

# Inject a controlled post-acquisition failure through the diagnostic write stub. The exact
# private single-flight wrapper must leave the lease in place and a same-session retry must fail.
$failure = New-InputSet 'failure' 'single-flight-failure'
$env:BRAINTRUST_SINGLE_FLIGHT_DIAGNOSTIC_WRITE_MODE = 'fail-after-lease'
$failureObserved = $false
$failureReason = ''
try {
    & $exchange @failure | Out-Null
} catch {
    $failureReason = $_.Exception.Message
    if ($failureReason -like 'DIAGNOSTIC_WRITE_FAILURE_AFTER_SINGLE_FLIGHT_LEASE*') { $failureObserved = $true }
}
Remove-Item Env:BRAINTRUST_SINGLE_FLIGHT_DIAGNOSTIC_WRITE_MODE -ErrorAction SilentlyContinue
if (-not $failureObserved) { throw "Injected post-acquisition failure was not observed: $failureReason" }
if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) { throw 'Lease was not retained after injected post-acquisition failure.' }
$failureLeaseSha = Sha $leasePath

$retry = New-InputSet 'retry-after-failure' 'single-flight-retry-after-failure'
$retryRejected = $false
$retryReason = ''
try {
    & $exchange @retry | Out-Null
} catch {
    $retryReason = $_.Exception.Message
    if ($retryReason -like 'MCP_STDIO_SINGLE_FLIGHT_BUSY_OR_STALE:*') { $retryRejected = $true }
}
if (-not $retryRejected) { throw "Same-session retry was not blocked by retained failure lease: $retryReason" }
if ((Sha $leasePath) -ne $failureLeaseSha) { throw 'Retained failure lease changed during blocked retry.' }

# Diagnostic cleanup is explicit and manual. This does not model production crash recovery.
Remove-Item -LiteralPath $leasePath -Force

Write-Json $OutputPath ([ordered]@{
    schemaVersion = 1
    component = 'public-windows-stdio-single-flight-lease-canary'
    diagnosticOnly = $true
    shellLabel = $ShellLabel
    powerShellEdition = $PSVersionTable.PSEdition
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    osVersion = [Environment]::OSVersion.Version.ToString()
    architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    exactPrivateSingleFlightBlob = '36cd9a2f93bfd0012e799b6792effd0dc81e625d'
    exactPrivateStrictJsonBlob = '4bc29ae306b613aafcc37c4bc63e54e321a38eb2'
    session = [ordered]@{
        processId = [int]$process.Id
        processStartTimeUtc = $startTime.ToString('o')
        imagePath = $imagePath
        imageBackingFileSha256 = $imageSha
        sessionKeySha256 = $sessionKeySha
    }
    sequentialReuse = [ordered]@{
        firstSuccessReleasedLease = $true
        secondSuccessReacquiredAndReleasedLease = $true
    }
    overlappingContention = [ordered]@{
        winnerHeldLeaseAcrossDiagnosticWrite = $true
        secondCallerRejectedWhileLeaseExisted = $busyRejected
        rejectionReason = $busyReason
        rejectionElapsedMilliseconds = $busyElapsedMs
        winnerCompletedAndReleasedLease = $true
    }
    failureRetention = [ordered]@{
        injectedFailureAfterLeaseAcquisitionObserved = $failureObserved
        retainedLeaseSha256 = $failureLeaseSha
        sameSessionRetryBlockedWhileLeaseExists = $retryRejected
        retryRejectionReason = $retryReason
        automaticRetryAccepted = $false
        diagnosticManualCleanupPerformed = $true
        abruptProcessCrashNativeAccepted = $false
        crashRecoveryReplayAccepted = $false
    }
    acceptanceBoundary = [ordered]@{
        exactPrivateSingleFlightBytesNativeExecuted = $true
        exactPrivateStrictJsonBytesNativeExecuted = $true
        runtimeSingleFlightSequentialReuseNativeAccepted = $true
        runtimeSingleFlightOverlappingContentionNativeAccepted = $true
        runtimeSingleFlightFailureLeaseRetentionNativeAccepted = $true
        sameSessionRetryBlockedAfterFailureNativeAccepted = $true
        diagnosticWriteAndResponseGatesWereStubs = $true
        fullPrivateNearWireSenderChainNativeAcceptedByThisCanary = $false
        abruptProcessCrashNativeAccepted = $false
        crashRecoveryReplayAccepted = $false
        powerLossDurabilityAccepted = $false
        runtimeBypassCryptographicallyPrevented = $false
        exactlyOnceToolSideEffectProven = $false
        semanticToolAccepted = $false
        windowsFinalStateAccepted = $false
    }
})
