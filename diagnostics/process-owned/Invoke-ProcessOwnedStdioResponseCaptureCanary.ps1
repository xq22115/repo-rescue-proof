param(
    [Parameter(Mandatory = $true)][string]$ShellLabel,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$capture = Join-Path $root 'Read-Windows-Mcp-ProcessOwnedStdioResponseArtifact.ps1'
function Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
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
    [IO.File]::WriteAllText($full, ($Object | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
}
function Start-ResponseChild([string]$Tag, [string]$RequestId) {
    $childScript = Join-Path $env:RUNNER_TEMP ("process-owned-response-child-$Tag-" + [guid]::NewGuid().ToString('N') + '.ps1')
    $escapedRequestId = $RequestId.Replace("'", "''")
    $childSource = @"
`$response = [ordered]@{
    id = '$escapedRequestId'
    jsonrpc = '2.0'
    result = [ordered]@{
        isError = `$false
        resultType = 'complete'
        structuredContent = [ordered]@{ source = '$Tag'; value = 42 }
    }
}
`$json = `$response | ConvertTo-Json -Depth 10 -Compress
[byte[]]`$body = [Text.UTF8Encoding]::new(`$false).GetBytes(`$json)
[byte[]]`$frame = New-Object byte[] (`$body.Length + 1)
[Buffer]::BlockCopy(`$body, 0, `$frame, 0, `$body.Length)
`$frame[`$frame.Length - 1] = 0x0A
`$stdout = [Console]::OpenStandardOutput()
`$stdout.Write(`$frame, 0, `$frame.Length)
`$stdout.Flush()
Start-Sleep -Seconds 6
"@
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
    if (-not $process.Start()) { throw 'response child start failed' }
    [pscustomobject]@{ Process = $process; Script = $childScript }
}

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    $started = [datetime]::UtcNow
    $rejected = $false
    $reason = ''
    try {
        & $capture `
            -TargetProcess (Get-Process -Id $PID) `
            -StdioSessionAffinityReceiptPath (Join-Path $env:RUNNER_TEMP 'absent-session.json') `
            -ExpectedStdioSessionAffinityReceiptSha256 ('00' * 32) `
            -FramePlanReceiptPath (Join-Path $env:RUNNER_TEMP 'absent-frame-plan.json') `
            -ExpectedFramePlanReceiptSha256 ('00' * 32) `
            -ResponseArtifactPath (Join-Path $env:RUNNER_TEMP 'must-not-exist-response.json') `
            -ReceiptPath (Join-Path $env:RUNNER_TEMP 'must-not-exist-capture.json') | Out-Null
    } catch {
        $reason = $_.Exception.Message
        if ($reason -like 'MCP_STDIO_TRANSPORT_HOST_UNSUPPORTED:*') { $rejected = $true }
    }
    $elapsedMs = [int](([datetime]::UtcNow - $started).TotalMilliseconds)
    if (-not $rejected) { throw "Windows PowerShell 5.1 was not rejected by response-capture transport policy: $reason" }
    if ($elapsedMs -gt 10000) { throw "Windows PowerShell 5.1 response-capture rejection was not fail-fast: ${elapsedMs}ms" }
    $output = [ordered]@{
        schemaVersion = 1
        component = 'public-windows-process-owned-stdio-response-capture-canary'
        diagnosticOnly = $true
        shellLabel = $ShellLabel
        powerShellEdition = $PSVersionTable.PSEdition
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        exactPrivateResponseCaptureBlob = '1800e2f6e8fe77053a398075e5eed0b2763ca95a'
        unsupportedTransportHost = [ordered]@{ rejectionObserved = $true; rejectionReason = $reason; rejectionElapsedMilliseconds = $elapsedMs }
        acceptanceBoundary = [ordered]@{
            exactProductionResponseCaptureBytesExercised = $true
            windowsPowerShell51FailFastTransportVetoAccepted = $true
            processOwnedResponseCaptureNativeAccepted = $false
            serverDeliveryCryptographicallyProven = $false
            responseOriginAuthenticated = $false
            semanticToolAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }
    Write-Json $OutputPath $output
    $output
    return
}

$work = Join-Path $env:RUNNER_TEMP ('process-owned-response-capture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$requestId = 'response-capture-1'
$primary = Start-ResponseChild 'primary' $requestId
$sibling = $null
try {
    Start-Sleep -Milliseconds 150
    $process = $primary.Process
    $imagePath = Image $process
    $imageSha = Sha $imagePath
    $startTime = ([datetimeoffset]$process.StartTime).ToUniversalTime().ToString('o')

    $spawnPath = Join-Path $work 'spawn.json'
    Write-Json $spawnPath ([ordered]@{ component='diagnostic-spawn'; pid=[int]$process.Id; startTimeUtc=$startTime; imagePath=$imagePath; imageSha256=$imageSha })
    $spawnSha = Sha $spawnPath
    $sessionPath = Join-Path $work 'session.json'
    Write-Json $sessionPath ([ordered]@{
        schemaVersion = 1
        component = 'windows-mcp-stdio-session-affinity-binding'
        expectedProtocolVersion = '2026-07-28'
        acceptanceBoundary = [ordered]@{ stdioCatalogProcessAffinityAccepted=$true; targetStreamOwnershipByBoundProcessProven=$false; sameTransportConnectionObjectProven=$false }
        processAffinity = [ordered]@{ processId=[int]$process.Id; processStartTimeUtc=$startTime; imagePath=$imagePath; imageBackingFileSha256=$imageSha }
        inputEvidence = [ordered]@{ targetSpawnedProcessIdentityReceiptPath=$spawnPath; targetSpawnedProcessIdentityReceiptSha256=$spawnSha }
    })
    $sessionSha = Sha $sessionPath

    $framePlanPath = Join-Path $work 'frame-plan.json'
    Write-Json $framePlanPath ([ordered]@{
        schemaVersion = 1
        component = 'windows-mcp-multi-server-stdio-tool-call-frame-plan'
        expectedProtocolVersion = '2026-07-28'
        transport = 'stdio'
        requestBinding = [ordered]@{ requestId=$requestId; rawProtocolToolName='search' }
    })
    $framePlanSha = Sha $framePlanPath
    $responsePath = Join-Path $work 'response.json'
    $captureReceiptPath = Join-Path $work 'response-capture.json'
    & $capture `
        -TargetProcess $process `
        -StdioSessionAffinityReceiptPath $sessionPath `
        -ExpectedStdioSessionAffinityReceiptSha256 $sessionSha `
        -FramePlanReceiptPath $framePlanPath `
        -ExpectedFramePlanReceiptSha256 $framePlanSha `
        -ResponseArtifactPath $responsePath `
        -ReceiptPath $captureReceiptPath `
        -ReadTimeoutMs 5000 | Out-Null

    $response = Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json
    if ($response.id -ne $requestId) { throw 'captured response id mismatch' }
    if ($response.result.structuredContent.source -ne 'primary') { throw 'captured response did not come from the primary diagnostic child' }
    if ([int]$response.result.structuredContent.value -ne 42) { throw 'captured response payload mismatch' }
    $captureReceipt = Get-Content -LiteralPath $captureReceiptPath -Raw | ConvertFrom-Json
    if (-not $captureReceipt.acceptanceBoundary.processOwnedResponseStreamConstructionAccepted) { throw 'process-owned response stream acceptance missing' }
    if (-not $captureReceipt.acceptanceBoundary.responseFrameObservedFromBoundProcessStandardOutput) { throw 'bound-process response observation missing' }
    if ($captureReceipt.acceptanceBoundary.responseOriginAuthenticated) { throw 'diagnostic must not overclaim authenticated response origin' }

    $sibling = Start-ResponseChild 'sibling' $requestId
    Start-Sleep -Milliseconds 150
    $siblingResponsePath = Join-Path $work 'sibling-response.json'
    $siblingReceiptPath = Join-Path $work 'sibling-capture.json'
    $siblingRejected = $false
    $siblingReason = ''
    try {
        & $capture `
            -TargetProcess $sibling.Process `
            -StdioSessionAffinityReceiptPath $sessionPath `
            -ExpectedStdioSessionAffinityReceiptSha256 $sessionSha `
            -FramePlanReceiptPath $framePlanPath `
            -ExpectedFramePlanReceiptSha256 $framePlanSha `
            -ResponseArtifactPath $siblingResponsePath `
            -ReceiptPath $siblingReceiptPath `
            -ReadTimeoutMs 1000 | Out-Null
    } catch {
        $siblingRejected = $true
        $siblingReason = $_.Exception.Message
    }
    if (-not $siblingRejected) { throw 'same-executable sibling response process was not rejected' }
    if ((Test-Path $siblingResponsePath) -or (Test-Path $siblingReceiptPath)) { throw 'sibling process produced response evidence unexpectedly' }

    $output = [ordered]@{
        schemaVersion = 1
        component = 'public-windows-process-owned-stdio-response-capture-canary'
        diagnosticOnly = $true
        shellLabel = $ShellLabel
        powerShellEdition = $PSVersionTable.PSEdition
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        osVersion = [Environment]::OSVersion.VersionString
        exactPrivateBlobs = [ordered]@{ responseCapture='1800e2f6e8fe77053a398075e5eed0b2763ca95a'; strictJsonHelper='4bc29ae306b613aafcc37c4bc63e54e321a38eb2' }
        primary = [ordered]@{
            processId = [int]$process.Id
            imagePath = $imagePath
            imageSha256 = $imageSha
            responseArtifactSha256 = Sha $responsePath
            responseId = $requestId
            capturedStructuredSource = [string]$response.result.structuredContent.source
            capturedStructuredValue = [int]$response.result.structuredContent.value
        }
        sibling = [ordered]@{
            processId = [int]$sibling.Process.Id
            sameExecutablePath = [string]::Equals((Image $sibling.Process), $imagePath, [StringComparison]::OrdinalIgnoreCase)
            sameExecutableSha256 = ((Sha (Image $sibling.Process)) -eq $imageSha)
            rejectedBeforeResponseRead = $true
            rejectionReason = $siblingReason
        }
        acceptanceBoundary = [ordered]@{
            exactProductionResponseCaptureBytesExercised = $true
            exactPrivateStrictJsonHelperBytesExercised = $true
            processOwnedResponseCaptureNativeAccepted = $true
            exactResponseArtifactBytesAccepted = $true
            responseIdMatchedRequest = $true
            sameExecutableSiblingProcessRejected = $true
            kernelPipePeerIdentityProven = $false
            responseOriginAuthenticated = $false
            serverDeliveryCryptographicallyProven = $false
            downstreamPhysicalServerIdentityAccepted = $false
            responseSchemaValidationAccepted = $false
            semanticToolAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }
    Write-Json $OutputPath $output
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
