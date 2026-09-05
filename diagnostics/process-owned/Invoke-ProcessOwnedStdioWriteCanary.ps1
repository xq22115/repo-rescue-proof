param(
    [Parameter(Mandatory = $true)][string]$ShellLabel,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapper = Join-Path $root 'Invoke-Windows-Mcp-ProcessOwnedNearWireStdioFrameWriteAttempt.ps1'
$strictHelper = Join-Path $root 'Get-BraintrustStrictJsonScalar.ps1'
$canonicalHelper = Join-Path $root 'ConvertTo-BraintrustCanonicalJson.ps1'
. $canonicalHelper

function Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Bytes-Sha([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}
function Image([Diagnostics.Process]$Process) {
    $path = $null
    try { $path = $Process.Path } catch {}
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $Process.MainModule.FileName }
    [IO.Path]::GetFullPath($path)
}
function Write-Json([string]$Path, [object]$Object) {
    $full = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $full
    if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    [IO.File]::WriteAllText($full, ($Object | ConvertTo-Json -Depth 40), (New-Object Text.UTF8Encoding($false)))
}
function Start-ProbeChild([string]$Tag) {
    $childScript = Join-Path $env:RUNNER_TEMP ("process-owned-child-$Tag-" + [guid]::NewGuid().ToString('N') + '.ps1')
    $childSource = @'
$stream = [Console]::OpenStandardInput()
$buffer = New-Object System.Collections.Generic.List[byte]
while ($true) {
    $value = $stream.ReadByte()
    if ($value -lt 0) { throw 'stdin ended before LF delimiter' }
    $buffer.Add([byte]$value)
    if ($value -eq 10) { break }
    if ($buffer.Count -gt 65536) { throw 'stdin frame exceeded diagnostic bound' }
}
$bytes = $buffer.ToArray()
$sha = [Security.Cryptography.SHA256]::Create()
try { $hash = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
[Console]::Out.WriteLine(('frame:' + $hash + ':' + $bytes.Length))
[Console]::Out.Flush()
Start-Sleep -Seconds 6
'@
    [IO.File]::WriteAllText($childScript, $childSource, (New-Object Text.UTF8Encoding($false)))
    $exe = Image (Get-Process -Id $PID)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' + $childScript + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw 'child start failed' }
    [pscustomobject]@{ Process = $process; Script = $childScript }
}

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    $started = [datetime]::UtcNow
    $rejected = $false
    $reason = ''
    try {
        & $wrapper `
            -TargetProcess (Get-Process -Id $PID) `
            -StdioSessionAffinityReceiptPath (Join-Path $env:RUNNER_TEMP 'intentionally-absent-session.json') `
            -ExpectedStdioSessionAffinityReceiptSha256 ('00' * 32) `
            -NearWireRevalidationReceiptPath (Join-Path $env:RUNNER_TEMP 'intentionally-absent-near-wire.json') `
            -ExpectedNearWireRevalidationReceiptSha256 ('00' * 32) `
            -FramePlanReceiptPath (Join-Path $env:RUNNER_TEMP 'intentionally-absent-frame-plan.json') `
            -ExpectedFramePlanReceiptSha256 ('00' * 32) `
            -ChildWriteAttemptReceiptPath (Join-Path $env:RUNNER_TEMP 'must-not-exist-child-write.json') `
            -NearWireWriteReceiptPath (Join-Path $env:RUNNER_TEMP 'must-not-exist-near-write.json') `
            -ReceiptPath (Join-Path $env:RUNNER_TEMP 'must-not-exist-wrapper.json') | Out-Null
    } catch {
        $reason = $_.Exception.Message
        if ($reason -like 'MCP_STDIO_TRANSPORT_HOST_UNSUPPORTED:*') { $rejected = $true }
    }
    $elapsedMs = [int](([datetime]::UtcNow - $started).TotalMilliseconds)
    if (-not $rejected) { throw "Windows PowerShell 5.1 was not rejected by the process-owned stdio transport boundary: $reason" }
    if ($elapsedMs -gt 10000) { throw "Windows PowerShell 5.1 transport-host rejection was not fail-fast: ${elapsedMs}ms" }
    $output = [ordered]@{
        schemaVersion = 3
        component = 'public-windows-process-owned-full-near-wire-stdio-canary'
        diagnosticOnly = $true
        shellLabel = $ShellLabel
        powerShellEdition = $PSVersionTable.PSEdition
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        exactPrivateBlobs = [ordered]@{
            processOwnedWrapper = '4d7515669e68b4ae6a44413a04d2d3284921b934'
            strictJsonHelper = '4bc29ae306b613aafcc37c4bc63e54e321a38eb2'
            canonicalJsonHelper = '0ed3d31e1bc13c20b5e4924b182ff77215f05893'
            nearWireSender = 'e148dec284f5c9fd280c605f9ec9b095050d5fff'
            lowerLevelSender = '2909c16aed847c22693bfe094de3ff076003013b'
        }
        unsupportedTransportHost = [ordered]@{
            expectedPolicy = 'PowerShell Core 7 or later'
            rejectionObserved = $true
            rejectionReason = $reason
            rejectionElapsedMilliseconds = $elapsedMs
        }
        acceptanceBoundary = [ordered]@{
            exactProductionProcessOwnedWrapperBytesExercised = $true
            windowsPowerShell51FailFastTransportVetoAccepted = $true
            fullProductionNearWireSenderChainNativeAccepted = $false
            nearWireSenderInvoked = $false
            lowerLevelSenderInvoked = $false
            liveDirectToolsListAcquired = $false
            generationCurrentAtActualWireSendProven = $false
            productionMcpServerReadObserved = $false
            downstreamPhysicalServerIdentityAccepted = $false
            toolExecutionAuthorized = $false
            semanticToolAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }
    Write-Json ([IO.Path]::GetFullPath($OutputPath)) $output
    $output
    return
}

$work = Join-Path $env:RUNNER_TEMP ('process-owned-full-chain-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$primary = Start-ProbeChild 'primary'
$sibling = $null
try {
    Start-Sleep -Milliseconds 150
    $process = $primary.Process
    $imagePath = Image $process
    $imageSha = Sha $imagePath
    $startTime = ([datetimeoffset]$process.StartTime).ToUniversalTime().ToString('o')

    $spawnPath = Join-Path $work 'spawn.json'
    Write-Json $spawnPath ([ordered]@{
        component = 'diagnostic-spawn'
        pid = [int]$process.Id
        startTimeUtc = $startTime
        imagePath = $imagePath
        imageSha256 = $imageSha
    })
    $spawnSha = Sha $spawnPath

    $sessionPath = Join-Path $work 'session.json'
    Write-Json $sessionPath ([ordered]@{
        schemaVersion = 1
        component = 'windows-mcp-stdio-session-affinity-binding'
        expectedProtocolVersion = '2026-07-28'
        acceptanceBoundary = [ordered]@{
            stdioCatalogProcessAffinityAccepted = $true
            targetStreamOwnershipByBoundProcessProven = $false
            sameTransportConnectionObjectProven = $false
        }
        processAffinity = [ordered]@{
            processId = [int]$process.Id
            processStartTimeUtc = $startTime
            imagePath = $imagePath
            imageBackingFileSha256 = $imageSha
        }
        inputEvidence = [ordered]@{
            targetSpawnedProcessIdentityReceiptPath = $spawnPath
            targetSpawnedProcessIdentityReceiptSha256 = $spawnSha
        }
    })
    $sessionSha = Sha $sessionPath

    $oldGenerationPath = Join-Path $work 'old-generation.json'
    Write-Json $oldGenerationPath ([ordered]@{ component = 'diagnostic-old-generation'; generation = 'g1' })
    $oldGenerationSha = Sha $oldGenerationPath
    $oldObservedPath = Join-Path $work 'old-tools-list.json'
    Write-Json $oldObservedPath ([ordered]@{ component = 'diagnostic-old-tools-list'; tools = @('search') })
    $oldObservedSha = Sha $oldObservedPath

    $preflightPath = Join-Path $work 'preflight.json'
    Write-Json $preflightPath ([ordered]@{
        schemaVersion = 1
        component = 'diagnostic-multi-server-execution-preflight'
        sourceEvidence = [ordered]@{
            catalogGenerationReceiptPath = $oldGenerationPath
            catalogGenerationReceiptSha256 = $oldGenerationSha
            observedToolsListResponsePath = $oldObservedPath
            observedToolsListResponseSha256 = $oldObservedSha
        }
    })
    $preflightSha = Sha $preflightPath

    $arguments = [ordered]@{ query = 'braintrust' }
    $argumentsCanonicalJson = ConvertTo-BraintrustCanonicalJson (ConvertTo-BraintrustCanonicalValue $arguments)
    $argumentsSha = Get-BraintrustUtf8Sha256 $argumentsCanonicalJson
    $routeSha = ('11' * 32)
    $decisionId = 'decision-1'

    $approvalPath = Join-Path $work 'approval-request.json'
    Write-Json $approvalPath ([ordered]@{
        schemaVersion = 1
        component = 'windows-mcp-multi-server-tool-approval-request'
        approvalRequest = [ordered]@{
            rawProtocolToolName = 'search'
            argumentsCanonicalSha256 = $argumentsSha
            arguments = $arguments
        }
    })
    $approvalSha = Sha $approvalPath

    $wireAttemptPath = Join-Path $work 'wire-attempt.json'
    Write-Json $wireAttemptPath ([ordered]@{
        schemaVersion = 1
        component = 'windows-mcp-multi-server-approval-effectuation-wire-attempt'
        attemptBinding = [ordered]@{
            outcomeKind = 'wire-attempt-started'
            approvalDecisionId = $decisionId
            generationRouteIdentitySha256 = $routeSha
            rawProtocolToolName = 'search'
            argumentsCanonicalSha256 = $argumentsSha
        }
        sourceEvidence = [ordered]@{
            multiServerExecutionPreflightReceiptPath = $preflightPath
            multiServerExecutionPreflightReceiptSha256 = $preflightSha
        }
    })
    $wireAttemptSha = Sha $wireAttemptPath

    $requestId = 'approval-decision:' + $decisionId
    $request = [ordered]@{
        id = $requestId
        jsonrpc = '2.0'
        method = 'tools/call'
        params = [ordered]@{
            _meta = [ordered]@{
                'io.modelcontextprotocol/clientCapabilities' = [ordered]@{}
                'io.modelcontextprotocol/protocolVersion' = '2026-07-28'
            }
            arguments = ConvertTo-BraintrustCanonicalValue $arguments
            name = 'search'
        }
    }
    $requestCanonicalJson = ConvertTo-BraintrustCanonicalJson $request
    [byte[]]$requestBytes = [Text.Encoding]::UTF8.GetBytes($requestCanonicalJson)
    [byte[]]$frameBytes = New-Object byte[] ($requestBytes.Length + 1)
    [Buffer]::BlockCopy($requestBytes, 0, $frameBytes, 0, $requestBytes.Length)
    $frameBytes[$frameBytes.Length - 1] = 0x0A
    $requestSha = Bytes-Sha $requestBytes
    $frameExpectedSha = Bytes-Sha $frameBytes

    $framePlanPath = Join-Path $work 'frame-plan.json'
    Write-Json $framePlanPath ([ordered]@{
        schemaVersion = 1
        component = 'windows-mcp-multi-server-stdio-tool-call-frame-plan'
        expectedProtocolVersion = '2026-07-28'
        transport = 'stdio'
        framingBoundary = [ordered]@{
            stdioFramePlanAccepted = $true
            jsonRpcToolsCallShapeAccepted = $true
            requiredRequestMetaPresent = $true
            utf8EncodedAccepted = $true
            newlineDelimitedJsonRpcAccepted = $true
            exactlyOneTrailingLfAccepted = $true
            noEmbeddedLfBytesAccepted = $true
            noCarriageReturnBytesAccepted = $true
            utf8BomAbsentAccepted = $true
            wireFrameBytesPersisted = $false
            actualTransportWriteObserved = $false
            wireRequestSent = $false
            deliveryOutcomeKnown = $false
            liveCatalogGenerationCurrentAtFrameConstructionProven = $false
            generationCurrentAtActualWireSendProven = $false
            downstreamPhysicalServerIdentityAccepted = $false
            authorizationContextAccepted = $false
            humanApprovalAccepted = $false
            toolExecutionAuthorized = $false
            exactlyOnceToolSideEffectProven = $false
            responseValidationGenerationAccepted = $false
            semanticToolAccepted = $false
            windowsFinalStateAccepted = $false
        }
        requestBinding = [ordered]@{
            requestId = $requestId
            rawProtocolToolName = 'search'
            generationRouteIdentitySha256 = $routeSha
            argumentsCanonicalSha256 = $argumentsSha
            requestBodyCanonicalSha256 = $requestSha
            requestBodyUtf8ByteLength = $requestBytes.Length
            wireFrameSha256 = $frameExpectedSha
            wireFrameByteLength = $frameBytes.Length
            modelVisibleExposedNameAcceptedAsWireToolName = $false
        }
        sourceEvidence = [ordered]@{
            wireAttemptReceiptPath = $wireAttemptPath
            wireAttemptReceiptSha256 = $wireAttemptSha
            approvalRequestReceiptPath = $approvalPath
            approvalRequestReceiptSha256 = $approvalSha
        }
    })
    $framePlanSha = Sha $framePlanPath

    $newGenerationPath = Join-Path $work 'near-generation.json'
    Write-Json $newGenerationPath ([ordered]@{ component = 'diagnostic-near-generation'; generation = 'g2'; rawTool = 'search' })
    $newGenerationSha = Sha $newGenerationPath
    $newObservedPath = Join-Path $work 'near-tools-list.json'
    Write-Json $newObservedPath ([ordered]@{ component = 'diagnostic-near-tools-list'; tools = @('search') })
    $newObservedSha = Sha $newObservedPath

    $nearPath = Join-Path $work 'near-wire.json'
    Write-Json $nearPath ([ordered]@{
        schemaVersion = 1
        component = 'windows-mcp-near-wire-selected-tool-generation-revalidation'
        expectedProtocolVersion = '2026-07-28'
        transport = 'stdio'
        nearWireSelectedToolGenerationRevalidationAccepted = $true
        routeBinding = [ordered]@{
            rawProtocolToolName = 'search'
            priorGenerationRouteIdentitySha256 = $routeSha
            exposedNameAcceptedAsWireToolName = $false
        }
        selectedToolBinding = [ordered]@{
            argumentsCanonicalSha256 = $argumentsSha
            selectedToolDefinitionMatchesApprovedPreflight = $true
            selectedInputSchemaMatchesApprovedPreflight = $true
        }
        freshnessBoundary = [ordered]@{
            nearWireGenerationReceiptGeneratedAfterExecutionPreflight = $true
            nearWireDirectLiveGenerationEvidenceAccepted = $true
            listChangedCanInvalidateAfterThisRevalidation = $true
            generationCanStillChangeAfterRevalidation = $true
            freshDirectToolsListRequestObservedByThisReceipt = $false
            ttlUsedAsEffectuationAuthority = $false
            subscriptionNotificationUsedAsSoleFreshnessAuthority = $false
            generationCurrentAtActualWireSendProven = $false
        }
        acceptanceBoundary = [ordered]@{
            executionPreflightExactReceiptBound = $true
            newerGenerationEvidenceBound = $true
            selectedToolDefinitionRevalidated = $true
            selectedInputSchemaRevalidated = $true
            directLiveGenerationEvidenceRequiredForProduction = $true
            downstreamPhysicalServerIdentityAccepted = $false
            authorizationContextAccepted = $false
            humanApprovalAccepted = $false
            toolExecutionAuthorized = $false
            wireRequestSent = $false
            responseValidationGenerationAccepted = $false
            semanticToolAccepted = $false
            windowsFinalStateAccepted = $false
        }
        sourceEvidence = [ordered]@{
            multiServerExecutionPreflightReceiptPath = $preflightPath
            multiServerExecutionPreflightReceiptSha256 = $preflightSha
            nearWireCatalogGenerationReceiptPath = $newGenerationPath
            nearWireCatalogGenerationReceiptSha256 = $newGenerationSha
            nearWireObservedToolsListResponsePath = $newObservedPath
            nearWireObservedToolsListResponseSha256 = $newObservedSha
        }
    })
    $nearSha = Sha $nearPath

    $childWritePath = Join-Path $work 'child-write.json'
    $nearWritePath = Join-Path $work 'near-write.json'
    $wrapperPath = Join-Path $work 'wrapper.json'
    & $wrapper `
        -TargetProcess $process `
        -StdioSessionAffinityReceiptPath $sessionPath `
        -ExpectedStdioSessionAffinityReceiptSha256 $sessionSha `
        -NearWireRevalidationReceiptPath $nearPath `
        -ExpectedNearWireRevalidationReceiptSha256 $nearSha `
        -FramePlanReceiptPath $framePlanPath `
        -ExpectedFramePlanReceiptSha256 $framePlanSha `
        -ChildWriteAttemptReceiptPath $childWritePath `
        -NearWireWriteReceiptPath $nearWritePath `
        -ReceiptPath $wrapperPath | Out-Null

    $childLine = $process.StandardOutput.ReadLine()
    $expectedLine = 'frame:' + $frameExpectedSha + ':' + $frameBytes.Length
    if ($childLine -ne $expectedLine) { throw "diagnostic child frame read-back mismatch: expected '$expectedLine', got '$childLine'" }

    $childWrite = Get-Content -LiteralPath $childWritePath -Raw | ConvertFrom-Json
    if (-not $childWrite.acceptanceBoundary.stdioFrameWriteAttemptRecorded) { throw 'low-level write receipt missing accepted write attempt' }
    if (-not $childWrite.writeObservation.localStreamWriteCompleted) { throw 'low-level local stream write did not complete' }
    if ($childWrite.acceptanceBoundary.wireRequestSent) { throw 'diagnostic chain must not overclaim wire delivery' }
    $nearWrite = Get-Content -LiteralPath $nearWritePath -Raw | ConvertFrom-Json
    if (-not $nearWrite.acceptanceBoundary.nearWireRevalidationRequiredAndBound) { throw 'near-wire receipt missing freshness binding' }
    $wrapperReceipt = Get-Content -LiteralPath $wrapperPath -Raw | ConvertFrom-Json
    if (-not $wrapperReceipt.acceptanceBoundary.processOwnedStreamConstructionAccepted) { throw 'process-owned wrapper acceptance missing' }

    $sibling = Start-ProbeChild 'sibling'
    Start-Sleep -Milliseconds 150
    $siblingChildWrite = Join-Path $work 'sibling-child-write.json'
    $siblingNearWrite = Join-Path $work 'sibling-near-write.json'
    $siblingWrapper = Join-Path $work 'sibling-wrapper.json'
    $rejected = $false
    $rejectionReason = ''
    try {
        & $wrapper `
            -TargetProcess $sibling.Process `
            -StdioSessionAffinityReceiptPath $sessionPath `
            -ExpectedStdioSessionAffinityReceiptSha256 $sessionSha `
            -NearWireRevalidationReceiptPath $nearPath `
            -ExpectedNearWireRevalidationReceiptSha256 $nearSha `
            -FramePlanReceiptPath $framePlanPath `
            -ExpectedFramePlanReceiptSha256 $framePlanSha `
            -ChildWriteAttemptReceiptPath $siblingChildWrite `
            -NearWireWriteReceiptPath $siblingNearWrite `
            -ReceiptPath $siblingWrapper | Out-Null
    } catch {
        $rejected = $true
        $rejectionReason = $_.Exception.Message
    }
    if (-not $rejected) { throw 'same-executable sibling process was not rejected' }
    if ((Test-Path $siblingChildWrite) -or (Test-Path $siblingNearWrite) -or (Test-Path $siblingWrapper)) { throw 'sibling reached sender or wrapper receipt generation unexpectedly' }

    $output = [ordered]@{
        schemaVersion = 3
        component = 'public-windows-process-owned-full-near-wire-stdio-canary'
        diagnosticOnly = $true
        shellLabel = $ShellLabel
        powerShellEdition = $PSVersionTable.PSEdition
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        osVersion = [Environment]::OSVersion.VersionString
        exactPrivateBlobs = [ordered]@{
            processOwnedWrapper = '4d7515669e68b4ae6a44413a04d2d3284921b934'
            strictJsonHelper = '4bc29ae306b613aafcc37c4bc63e54e321a38eb2'
            canonicalJsonHelper = '0ed3d31e1bc13c20b5e4924b182ff77215f05893'
            nearWireSender = 'e148dec284f5c9fd280c605f9ec9b095050d5fff'
            lowerLevelSender = '2909c16aed847c22693bfe094de3ff076003013b'
        }
        primary = [ordered]@{
            processId = [int]$process.Id
            imagePath = $imagePath
            imageSha256 = $imageSha
            plannedFrameSha256 = $frameExpectedSha
            plannedFrameByteLength = $frameBytes.Length
            diagnosticChildReadExactFrame = $true
            lowLevelLocalWriteCompleted = $true
            processOwnedWrapperAccepted = $true
        }
        sibling = [ordered]@{
            processId = [int]$sibling.Process.Id
            sameExecutablePath = [string]::Equals((Image $sibling.Process), $imagePath, [StringComparison]::OrdinalIgnoreCase)
            sameExecutableSha256 = ((Sha (Image $sibling.Process)) -eq $imageSha)
            rejectedBeforeNearWireSender = $true
            rejectionReason = $rejectionReason
        }
        acceptanceBoundary = [ordered]@{
            exactProductionProcessOwnedWrapperBytesExercised = $true
            exactPrivateStrictJsonHelperBytesExercised = $true
            exactPrivateCanonicalJsonHelperBytesExercised = $true
            exactProductionNearWireSenderBytesExercised = $true
            exactProductionLowerLevelSenderBytesExercised = $true
            structurallyValidSyntheticUpstreamEvidenceUsed = $true
            fullProductionNearWireSenderChainNativeAccepted = $true
            diagnosticChildReadExactPlannedFrame = $true
            sameExecutableSiblingProcessRejected = $true
            liveDirectToolsListAcquired = $false
            generationCurrentAtActualWireSendProven = $false
            productionMcpServerReadObserved = $false
            downstreamPhysicalServerIdentityAccepted = $false
            toolExecutionAuthorized = $false
            semanticToolAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }
    Write-Json ([IO.Path]::GetFullPath($OutputPath)) $output
    $output
} finally {
    foreach ($child in @($primary, $sibling)) {
        if ($null -ne $child) {
            try { if (-not $child.Process.HasExited) { $child.Process.Kill() } } catch {}
            try { $child.Process.Dispose() } catch {}
            try { Remove-Item -LiteralPath $child.Script -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}
