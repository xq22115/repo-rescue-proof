param(
    [ValidateSet('Parent','Worker')][string]$Mode = 'Parent',
    [string]$LeaseRootPath,
    [string]$WorkRootPath,
    [string]$OutputPath,
    [string]$ShellLabel = 'pwsh'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exchange = Join-Path $root 'single-flight\Invoke-Windows-Mcp-ProcessOwnedStdioSingleFlightExchange.ps1'
$recovery = Join-Path $root 'single-flight\Get-Windows-Mcp-StdioSingleFlightLeaseRecoveryEvidence.ps1'

function Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Image([Diagnostics.Process]$Process) {
    $path = $null
    try { $path = [string]$Process.Path } catch {}
    if ([string]::IsNullOrWhiteSpace($path)) { $path = [string]$Process.MainModule.FileName }
    [IO.Path]::GetFullPath($path)
}
function Bytes-Sha([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}
function Write-Json([string]$Path, [object]$Value) {
    $full = [IO.Path]::GetFullPath($Path)
    $dir = Split-Path -Parent $full
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($full, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
}

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Abrupt-termination single-flight canary requires PowerShell Core 7+.'
}

if ($Mode -eq 'Worker') {
    if ([string]::IsNullOrWhiteSpace($LeaseRootPath) -or [string]::IsNullOrWhiteSpace($WorkRootPath)) {
        throw 'Worker requires LeaseRootPath and WorkRootPath.'
    }
    New-Item -ItemType Directory -Force -Path $LeaseRootPath, $WorkRootPath | Out-Null
    $process = Get-Process -Id $PID
    $imagePath = Image $process
    $imageSha = Sha $imagePath
    $startTime = ([datetimeoffset]$process.StartTime).ToUniversalTime()

    $spawnPath = Join-Path $WorkRootPath 'spawn.json'
    Write-Json $spawnPath ([ordered]@{
        component = 'diagnostic-spawned-process'
        processId = [int]$process.Id
        processStartTimeUtc = $startTime.ToString('o')
        imagePath = $imagePath
        imageBackingFileSha256 = $imageSha
    })
    $spawnSha = Sha $spawnPath

    $sessionPath = Join-Path $WorkRootPath 'session.json'
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

    $near = Join-Path $WorkRootPath 'near.json'
    $frame = Join-Path $WorkRootPath 'frame.json'
    Write-Json $near ([ordered]@{ component = 'diagnostic-near-wire'; tag = 'abrupt-termination' })
    Write-Json $frame ([ordered]@{ requestBinding = [ordered]@{ requestId = 'abrupt-termination-request' } })

    $env:BRAINTRUST_SINGLE_FLIGHT_DIAGNOSTIC_HOLD_MS = '30000'
    try {
        & $exchange `
            -TargetProcess $process `
            -StdioSessionAffinityReceiptPath $sessionPath `
            -ExpectedStdioSessionAffinityReceiptSha256 $sessionSha `
            -NearWireRevalidationReceiptPath $near `
            -ExpectedNearWireRevalidationReceiptSha256 (Sha $near) `
            -FramePlanReceiptPath $frame `
            -ExpectedFramePlanReceiptSha256 (Sha $frame) `
            -ChildWriteAttemptReceiptPath (Join-Path $WorkRootPath 'child-write.json') `
            -NearWireWriteReceiptPath (Join-Path $WorkRootPath 'near-write.json') `
            -ProcessOwnedWriteReceiptPath (Join-Path $WorkRootPath 'process-write.json') `
            -ResponseArtifactPath (Join-Path $WorkRootPath 'response.json') `
            -ResponseCaptureReceiptPath (Join-Path $WorkRootPath 'response-capture.json') `
            -LeaseRootPath $LeaseRootPath `
            -ReceiptPath (Join-Path $WorkRootPath 'exchange.json') `
            -WriteTimeoutMs 5000 `
            -ReadTimeoutMs 5000 `
            -MaxFrameBytes 1048576 `
            -ExpectedProtocolVersion '2026-07-28' `
            -Transport 'stdio' | Out-Null
    } finally {
        Remove-Item Env:BRAINTRUST_SINGLE_FLIGHT_DIAGNOSTIC_HOLD_MS -ErrorAction SilentlyContinue
    }
    throw 'Worker unexpectedly completed instead of being externally terminated.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) { throw 'Parent requires OutputPath.' }
$work = Join-Path $env:RUNNER_TEMP ('stdio-single-flight-abrupt-' + [guid]::NewGuid().ToString('N'))
$leaseRoot = Join-Path $work 'leases'
$workerRoot = Join-Path $work 'worker'
New-Item -ItemType Directory -Force -Path $work, $leaseRoot, $workerRoot | Out-Null

$currentPwsh = [Environment]::ProcessPath
if ([string]::IsNullOrWhiteSpace($currentPwsh)) { $currentPwsh = (Get-Process -Id $PID).Path }
$currentPwsh = [IO.Path]::GetFullPath($currentPwsh)
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $currentPwsh
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.Arguments = ('-NoLogo -NoProfile -NonInteractive -File "{0}" -Mode Worker -LeaseRootPath "{1}" -WorkRootPath "{2}" -ShellLabel "{3}"' -f $MyInvocation.MyCommand.Path, $leaseRoot, $workerRoot, $ShellLabel)
$worker = [Diagnostics.Process]::new()
$worker.StartInfo = $psi
if (-not $worker.Start()) { throw 'Unable to start abrupt-termination worker.' }
$workerPid = [int]$worker.Id

try {
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    $leasePath = $null
    while ($null -eq $leasePath) {
        $leases = @(Get-ChildItem -LiteralPath $leaseRoot -Filter '*.stdio-single-flight.json' -File -ErrorAction SilentlyContinue)
        if ($leases.Count -eq 1) { $leasePath = $leases[0].FullName; break }
        if ($leases.Count -gt 1) { throw 'Expected exactly one single-flight lease during abrupt-termination canary.' }
        if ($worker.HasExited) { throw "Worker exited before acquiring lease. exit=$($worker.ExitCode)" }
        if ([datetime]::UtcNow -gt $deadline) { throw 'Worker did not acquire single-flight lease within 15 seconds.' }
        Start-Sleep -Milliseconds 25
    }

    $leaseShaBeforeKill = Sha $leasePath
    $leaseBytesBeforeKill = [IO.File]::ReadAllBytes($leasePath)
    $leaseJson = ((Get-Content -LiteralPath $leasePath -Raw) | ConvertFrom-Json -ErrorAction Stop)
    if ([int]$leaseJson.processIdentity.processId -ne $workerPid) { throw 'Lease PID does not identify the abrupt-termination worker process.' }

    $liveReceiptPath = Join-Path $work 'live-recovery.json'
    $liveReceipt = & $recovery -LeasePath $leasePath -ExpectedLeaseSha256 $leaseShaBeforeKill -ReceiptPath $liveReceiptPath
    if ($liveReceipt.recoveryClassification.state -ne 'live-session-busy') { throw 'Recovery classifier did not identify live session as busy.' }
    if (-not $liveReceipt.recoveryClassification.liveSessionBusy) { throw 'Live recovery receipt did not retain liveSessionBusy=true.' }
    if ($liveReceipt.recoveryClassification.freshSessionRequired) { throw 'Live session incorrectly required a fresh session.' }

    # Abruptly terminate the exact process lifetime that owns the lease. This bypasses the
    # wrapper's normal finally/success path and is intentionally different from an injected exception.
    Stop-Process -Id $workerPid -Force -ErrorAction Stop
    if (-not $worker.WaitForExit(10000)) { throw 'Abrupt-termination worker did not exit after Stop-Process -Force.' }

    if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) { throw 'Single-flight lease disappeared after abrupt process termination.' }
    $leaseShaAfterKill = Sha $leasePath
    $leaseBytesAfterKill = [IO.File]::ReadAllBytes($leasePath)
    if ($leaseShaAfterKill -ne $leaseShaBeforeKill) { throw 'Single-flight lease SHA changed after abrupt process termination.' }
    if ($leaseBytesAfterKill.Length -ne $leaseBytesBeforeKill.Length) { throw 'Single-flight lease byte length changed after abrupt process termination.' }

    $abandonedReceiptPath = Join-Path $work 'abandoned-recovery.json'
    $abandonedReceipt = & $recovery -LeasePath $leasePath -ExpectedLeaseSha256 $leaseShaBeforeKill -ReceiptPath $abandonedReceiptPath
    if ($abandonedReceipt.recoveryClassification.state -ne 'abandoned-session-process-missing') { throw 'Recovery classifier did not identify terminated session process as abandoned.' }
    if (-not $abandonedReceipt.recoveryClassification.freshSessionRequired) { throw 'Abandoned session did not require a fresh session.' }
    if (-not $abandonedReceipt.recoveryClassification.manualRecoveryRequired) { throw 'Abandoned session did not require manual recovery.' }
    if ($abandonedReceipt.acceptanceBoundary.staleLeaseAutomaticallyDeleted) { throw 'Recovery classifier deleted or accepted deletion of stale lease.' }
    if ($abandonedReceipt.acceptanceBoundary.sameSessionReplayAuthorized) { throw 'Recovery classifier authorized same-session replay.' }
    if ($abandonedReceipt.acceptanceBoundary.automaticRetryAccepted) { throw 'Recovery classifier authorized automatic retry.' }
    if ($abandonedReceipt.acceptanceBoundary.crashRecoveryReplayAccepted) { throw 'Recovery classifier authorized crash-recovery replay.' }
    if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) { throw 'Recovery classifier removed abandoned lease evidence.' }
    if ((Sha $leasePath) -ne $leaseShaBeforeKill) { throw 'Abandoned lease changed during recovery classification.' }

    Write-Json $OutputPath ([ordered]@{
        schemaVersion = 1
        component = 'public-windows-stdio-single-flight-abrupt-termination-canary'
        diagnosticOnly = $true
        shellLabel = $ShellLabel
        powerShellEdition = $PSVersionTable.PSEdition
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        osVersion = [Environment]::OSVersion.Version.ToString()
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        exactPrivateSingleFlightBlob = '36cd9a2f93bfd0012e799b6792effd0dc81e625d'
        exactPrivateStrictJsonBlob = '4bc29ae306b613aafcc37c4bc63e54e321a38eb2'
        exactPrivateRecoveryClassifierBlob = 'a504cb7374710171d46e7880bf36835059cdd892'
        abruptTermination = [ordered]@{
            workerProcessId = $workerPid
            liveClassificationBeforeKill = $liveReceipt.recoveryClassification.state
            workerKilledExternally = $true
            workerExitCode = $worker.ExitCode
            leaseSha256BeforeKill = $leaseShaBeforeKill
            leaseSha256AfterKill = $leaseShaAfterKill
            leaseByteLength = $leaseBytesBeforeKill.Length
            abandonedClassificationAfterKill = $abandonedReceipt.recoveryClassification.state
            leaseStillExistsAfterClassification = (Test-Path -LiteralPath $leasePath -PathType Leaf)
            leaseUnchangedAfterClassification = ((Sha $leasePath) -eq $leaseShaBeforeKill)
        }
        recoveryPolicy = [ordered]@{
            staleLeaseAutomaticallyDeleted = $false
            sameSessionReplayAuthorized = $false
            automaticRetryAccepted = $false
            crashRecoveryReplayAccepted = $false
            freshSessionRequired = $true
            manualRecoveryRequired = $true
        }
        acceptanceBoundary = [ordered]@{
            exactPrivateSingleFlightBytesUsedToCreateLease = $true
            exactPrivateStrictJsonBytesUsed = $true
            exactPrivateRecoveryClassifierBytesNativeExecuted = $true
            abruptSessionProcessTerminationLeaseRetentionNativeAccepted = $true
            liveSessionBusyClassificationNativeAccepted = $true
            abandonedProcessMissingClassificationNativeAccepted = $true
            leaseIntegrityPreservedAcrossAbruptTermination = $true
            automaticStaleLeaseDeletionAccepted = $false
            automaticRetryAfterUnknownDeliveryAccepted = $false
            crashRecoveryReplayAccepted = $false
            abruptOsCrashOrPowerLossAccepted = $false
            powerLossDurabilityAccepted = $false
            exactlyOnceToolSideEffectProven = $false
            semanticToolAccepted = $false
            windowsFinalStateAccepted = $false
        }
    })
} finally {
    if (-not $worker.HasExited) { try { $worker.Kill($true) } catch {}; try { [void]$worker.WaitForExit(5000) } catch {} }
    $worker.Dispose()
    # Diagnostic cleanup is deliberately manual and only after all retained-lease evidence has been captured.
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
