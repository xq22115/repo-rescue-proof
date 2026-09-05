param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidateRange(100, 30000)][int]$WriteTimeoutMs = 5000,
    [ValidateRange(100, 30000)][int]$ChildTimeoutMs = 5000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function ConvertTo-WindowsProcessArgument([string]$Value) {
    $quote = [char]34
    $slash = [string][char]92
    if ($null -eq $Value) { return ([string]$quote + [string]$quote) }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append($quote)
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]92) { $slashes++; continue }
        if ($ch -eq $quote) {
            if ($slashes -gt 0) { [void]$builder.Append(($slash * ($slashes * 2))) }
            [void]$builder.Append($slash)
            [void]$builder.Append($quote)
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(($slash * $slashes)); $slashes = 0 }
        [void]$builder.Append($ch)
    }
    if ($slashes -gt 0) { [void]$builder.Append(($slash * ($slashes * 2))) }
    [void]$builder.Append($quote)
    return $builder.ToString()
}

if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
    throw 'This canary requires native Windows.'
}

$request = [ordered]@{
    id = 'approval-decision:11111111-1111-1111-1111-111111111111'
    jsonrpc = '2.0'
    method = 'tools/call'
    params = [ordered]@{
        _meta = [ordered]@{
            'io.modelcontextprotocol/clientCapabilities' = [ordered]@{}
            'io.modelcontextprotocol/protocolVersion' = '2026-07-28'
        }
        arguments = [ordered]@{
            query = 'windows mcp'
            topK = 5
        }
        name = 'search'
    }
}
$expectedJson = '{"id":"approval-decision:11111111-1111-1111-1111-111111111111","jsonrpc":"2.0","method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/protocolVersion":"2026-07-28"},"arguments":{"query":"windows mcp","topK":5},"name":"search"}}'
$expectedBodySha256 = '43851d9bf1d04cc02c8e058935d339d9f1a562f012532bb548689a572ee512d6'
$expectedFrameSha256 = '11907df6b04f6290de10403d1df67c8937654e5a0e6853b62578fce0079af0c5'

$json = $request | ConvertTo-Json -Depth 20 -Compress
if (-not [string]::Equals($json, $expectedJson, [System.StringComparison]::Ordinal)) { throw 'Canonical request JSON differs from locked expected JSON.' }
[byte[]]$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
[byte[]]$frameBytes = New-Object byte[] ($bodyBytes.Length + 1)
[System.Buffer]::BlockCopy($bodyBytes, 0, $frameBytes, 0, $bodyBytes.Length)
$frameBytes[$frameBytes.Length - 1] = 0x0A
$bodySha256 = Get-Sha256 $bodyBytes
$frameSha256 = Get-Sha256 $frameBytes
if ($bodySha256 -ne $expectedBodySha256) { throw "Body SHA-256 mismatch: $bodySha256" }
if ($frameSha256 -ne $expectedFrameSha256) { throw "Frame SHA-256 mismatch: $frameSha256" }
if ($bodyBytes.Length -ne 286 -or $frameBytes.Length -ne 287) { throw 'Locked request byte lengths changed.' }

$readerScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Read-OneStdioFrame.ps1'))
if (-not (Test-Path -LiteralPath $readerScript -PathType Leaf)) { throw 'Child stdio frame reader was not found.' }
$fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $fullOutputPath
if ($outputDirectory) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
$childReceiptPath = [System.IO.Path]::Combine($outputDirectory, ([System.IO.Path]::GetFileNameWithoutExtension($fullOutputPath) + '.child.json'))
if (Test-Path -LiteralPath $childReceiptPath) { Remove-Item -LiteralPath $childReceiptPath -Force }

$enginePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) { throw "Current PowerShell engine path was not readable: $enginePath" }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $enginePath
$psi.Arguments = ('-NoLogo -NoProfile -NonInteractive -File {0} -OutputPath {1}' -f (ConvertTo-WindowsProcessArgument $readerScript), (ConvertTo-WindowsProcessArgument $childReceiptPath))
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
# On Windows PowerShell 5.1/.NET Framework, Process.StandardInput is a StreamWriter.
# If its encoding has a UTF-8 preamble, merely taking BaseStream can leave BOM bytes ahead of our raw MCP frame.
# Force an explicit no-BOM UTF-8 encoding before Process.Start so BaseStream begins at the first caller byte.
$psi.StandardInputEncoding = New-Object System.Text.UTF8Encoding($false)
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
$writeInvocationCount = 0
$localWriteCompleted = $false
try {
    if (-not $process.Start()) { throw 'Failed to start child PowerShell frame reader.' }
    $targetStream = $process.StandardInput.BaseStream
    $writeInvocationCount++
    $writeTask = $targetStream.WriteAsync($frameBytes, 0, $frameBytes.Length)
    if (-not $writeTask.Wait($WriteTimeoutMs)) {
        throw 'Single stdio WriteAsync did not settle within the canary timeout.'
    }
    if ($writeTask.IsFaulted) { throw "Single stdio WriteAsync faulted: $($writeTask.Exception.GetBaseException().GetType().FullName)" }
    if ($writeTask.IsCanceled) { throw 'Single stdio WriteAsync was canceled.' }
    $localWriteCompleted = $true
    $process.StandardInput.Close()

    if (-not $process.WaitForExit($ChildTimeoutMs)) {
        try { $process.Kill() } catch {}
        throw 'Child frame reader did not exit within the canary timeout.'
    }
    $childStdout = $process.StandardOutput.ReadToEnd()
    $childStderr = $process.StandardError.ReadToEnd()
    if ($process.ExitCode -ne 0) { throw "Child frame reader failed with exit code $($process.ExitCode): $childStderr" }
    if (-not (Test-Path -LiteralPath $childReceiptPath -PathType Leaf)) { throw 'Child frame reader did not persist its receipt.' }
    $childReceipt = (Get-Content -LiteralPath $childReceiptPath -Raw) | ConvertFrom-Json
    if ([string]$childReceipt.component -ne 'public-windows-mcp-stdio-child-frame-read') { throw 'Child receipt component mismatch.' }
    if (-not [bool]$childReceipt.acceptance.childStdioFrameReadAccepted) { throw 'Child did not accept the stdio frame.' }
    if ([string]$childReceipt.frame.sha256 -ne $frameSha256) { throw 'Child-observed frame SHA-256 differs from the single parent write.' }
    if ([int]$childReceipt.frame.byteLength -ne $frameBytes.Length) { throw 'Child-observed frame length differs from the single parent write.' }
    if ([string]$childReceipt.frame.bodySha256 -ne $bodySha256) { throw 'Child-observed body SHA-256 differs from the parent body.' }

    if ($writeInvocationCount -ne 1) { throw "Expected exactly one WriteAsync invocation; observed $writeInvocationCount." }
    $receipt = [ordered]@{
        schemaVersion = 2
        component = 'public-windows-mcp-stdio-single-write-canary'
        generatedAtUtc = [datetime]::UtcNow.ToString('o')
        runtime = [ordered]@{
            osDescription = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
            osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
            frameworkDescription = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
            psEdition = $PSVersionTable.PSEdition
            psVersion = $PSVersionTable.PSVersion.ToString()
            enginePath = $enginePath
        }
        frame = [ordered]@{
            byteLength = $frameBytes.Length
            sha256 = $frameSha256
            bodyByteLength = $bodyBytes.Length
            bodySha256 = $bodySha256
            exactlyOneLf = $true
            noCarriageReturn = $true
            utf8BomAbsent = $true
        }
        processStdio = [ordered]@{
            standardInputEncodingExplicitUtf8NoBom = $true
            rawWriteUsesStandardInputBaseStream = $true
            firstObservedChildFrameByteIsCallerFrameByte = $true
        }
        writeAttempt = [ordered]@{
            writeAsyncInvocationCount = $writeInvocationCount
            exactlyOneWriteAsyncInvocationAccepted = ($writeInvocationCount -eq 1)
            localStreamWriteCompletedWithinBound = $localWriteCompleted
            automaticRetryPerformed = $false
            childProcessExitCode = $process.ExitCode
            childStdoutSha256 = Get-Sha256 ([System.Text.Encoding]::UTF8.GetBytes($childStdout))
            childStderrSha256 = Get-Sha256 ([System.Text.Encoding]::UTF8.GetBytes($childStderr))
        }
        childObservation = [ordered]@{
            childReceiptPath = $childReceiptPath
            childFrameSha256 = [string]$childReceipt.frame.sha256
            childFrameByteLength = [int]$childReceipt.frame.byteLength
            exactFrameBytesObservedByChild = $true
        }
        acceptance = [ordered]@{
            singleCallerWriteInvocationAccepted = $true
            localStreamWriteCompleted = $true
            childPipeReadObserved = $true
            exactFrameObservedByChild = $true
            processStandardInputBomPreflightAccepted = $true
            atomicOsPipeWriteProven = $false
            mcpServerReceiptProven = $false
            mcpToolExecutionAccepted = $false
            deliveryBeyondChildPipeReadAccepted = $false
            semanticToolAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }
    [System.IO.File]::WriteAllText($fullOutputPath, ($receipt | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "MCP_STDIO_SINGLE_WRITE_CANARY_PASS frame=$frameSha256 child=$($childReceipt.frame.sha256)"
} finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) { try { $process.Kill() } catch {} }
        $process.Dispose()
    }
}
