param(
    [Parameter(Mandatory = $true)][string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
    throw 'This diagnostic requires native Windows.'
}
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This diagnostic requires PowerShell Core 7 or newer.'
}

$encoding = New-Object System.Text.UTF8Encoding($false)
$probe = New-Object System.Diagnostics.ProcessStartInfo
if ($null -eq $probe.PSObject.Properties['StandardInputEncoding']) {
    throw 'ProcessStartInfo.StandardInputEncoding is not available in this runtime.'
}

$childScript = Join-Path $PSScriptRoot 'read-stdin-raw.ps1'
if (-not (Test-Path -LiteralPath $childScript -PathType Leaf)) {
    throw "Missing raw stdin reader: $childScript"
}
$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source

$bodyText = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"q":"taipei"}}}'
$bodyBytes = $encoding.GetBytes($bodyText)
$frame = New-Object byte[] ($bodyBytes.Length + 1)
[Array]::Copy($bodyBytes, 0, $frame, 0, $bodyBytes.Length)
$frame[$frame.Length - 1] = 0x0A
$expectedBase64 = [Convert]::ToBase64String($frame)
$hasher = [System.Security.Cryptography.SHA256]::Create()
try {
    $expectedSha256 = (($hasher.ComputeHash($frame) | ForEach-Object { $_.ToString('x2') }) -join '')
} finally {
    $hasher.Dispose()
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $pwsh
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardInputEncoding = $encoding
$null = $psi.ArgumentList.Add('-NoLogo')
$null = $psi.ArgumentList.Add('-NoProfile')
$null = $psi.ArgumentList.Add('-NonInteractive')
$null = $psi.ArgumentList.Add('-File')
$null = $psi.ArgumentList.Add($childScript)

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
if (-not $process.Start()) { throw 'Failed to start child pwsh process.' }
try {
    $process.StandardInput.BaseStream.Write($frame, 0, $frame.Length)
    $process.StandardInput.BaseStream.Flush()
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(10000)) {
        try { $process.Kill($true) } catch { }
        throw 'Child pwsh raw stdin reader timed out.'
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    if ($process.ExitCode -ne 0) {
        throw "Child pwsh exited $($process.ExitCode): $stderr"
    }
    $observed = $stdout | ConvertFrom-Json -ErrorAction Stop
    if ($observed.base64 -ne $expectedBase64) {
        throw "Redirected stdin bytes differ. expected=$expectedSha256 observed=$($observed.sha256) prefix=$($observed.hexPrefix)"
    }
    if ([int]$observed.byteLength -ne $frame.Length) { throw 'Redirected stdin byte length differs.' }
    if ([string]$observed.sha256 -ne $expectedSha256) { throw 'Redirected stdin SHA-256 differs.' }

    $receipt = [ordered]@{
        schemaVersion = 1
        component = 'public-windows-pwsh7-redirected-stdin-no-bom-canary'
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        runner = [ordered]@{
            os = $env:RUNNER_OS
            arch = $env:RUNNER_ARCH
            image = $env:ImageOS
            imageVersion = $env:ImageVersion
            powershellEdition = $PSVersionTable.PSEdition
            powershellVersion = $PSVersionTable.PSVersion.ToString()
        }
        processStartInfo = [ordered]@{
            standardInputEncodingPropertyAvailable = $true
            standardInputEncodingWebName = $psi.StandardInputEncoding.WebName
            standardInputEncodingPreambleLength = $psi.StandardInputEncoding.GetPreamble().Length
        }
        observation = [ordered]@{
            exactFrameBytesMatched = $true
            utf8BomObserved = $false
            carriageReturnObserved = $false
            expectedFrameByteLength = $frame.Length
            expectedFrameSha256 = $expectedSha256
            observedFrameByteLength = [int]$observed.byteLength
            observedFrameSha256 = [string]$observed.sha256
            observedHexPrefix = [string]$observed.hexPrefix
        }
        acceptance = [ordered]@{
            pwsh7RedirectedStdinNoBomAccepted = $true
            windowsPowerShell51RedirectedStdinAccepted = $false
            rawWin32PipeHelperAccepted = $false
            privateBraintrustRuntimeBrokerAccepted = $false
            mcpWireDeliveryAccepted = $false
            semanticToolAccepted = $false
        }
    }
    $directory = Split-Path -Parent $ReceiptPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReceiptPath -Encoding utf8NoBOM
    Write-Host "PWSh7 redirected stdin exact-frame canary PASS sha256=$expectedSha256"
} finally {
    $process.Dispose()
}
