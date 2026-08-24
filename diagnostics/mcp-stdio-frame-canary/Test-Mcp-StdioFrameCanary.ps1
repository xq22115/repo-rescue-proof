param(
    [Parameter(Mandatory = $true)][string]$OutputPath
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
# These constants were independently recomputed from the literal UTF-8 bytes of $expectedJson.
$expectedBodySha256 = '43851d9bf1d04cc02c8e058935d339d9f1a562f012532bb548689a572ee512d6'
$expectedFrameSha256 = '11907df6b04f6290de10403d1df67c8937654e5a0e6853b62578fce0079af0c5'

$json = $request | ConvertTo-Json -Depth 20 -Compress
if (-not [string]::Equals($json, $expectedJson, [System.StringComparison]::Ordinal)) {
    throw "Canonical JSON differs from the cross-language expected bytes. Observed: $json"
}
if ($json.Contains("`r") -or $json.Contains("`n")) {
    throw 'Compressed JSON contains an embedded physical CR/LF.'
}

$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
$frameBytes = New-Object byte[] ($bodyBytes.Length + 1)
[System.Buffer]::BlockCopy($bodyBytes, 0, $frameBytes, 0, $bodyBytes.Length)
$frameBytes[$frameBytes.Length - 1] = 0x0A

$bodySha256 = Get-Sha256 $bodyBytes
$frameSha256 = Get-Sha256 $frameBytes
if ($bodySha256 -ne $expectedBodySha256) { throw "Body SHA-256 mismatch: $bodySha256" }
if ($frameSha256 -ne $expectedFrameSha256) { throw "Frame SHA-256 mismatch: $frameSha256" }
if ($bodyBytes.Length -ne 286) { throw "Body byte length mismatch: $($bodyBytes.Length)" }
if ($frameBytes.Length -ne 287) { throw "Frame byte length mismatch: $($frameBytes.Length)" }
if (($frameBytes | Where-Object { $_ -eq 0x0A }).Count -ne 1) { throw 'Frame must contain exactly one LF byte.' }
if (($frameBytes | Where-Object { $_ -eq 0x0D }).Count -ne 0) { throw 'Frame must not contain CR bytes.' }
if ($frameBytes[$frameBytes.Length - 1] -ne 0x0A) { throw 'Frame must end in LF.' }
if ($frameBytes.Length -ge 3 -and $frameBytes[0] -eq 0xEF -and $frameBytes[1] -eq 0xBB -and $frameBytes[2] -eq 0xBF) { throw 'Frame must not contain a UTF-8 BOM.' }

$runtime = [ordered]@{
    osDescription = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    frameworkDescription = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
    psEdition = $PSVersionTable.PSEdition
    psVersion = $PSVersionTable.PSVersion.ToString()
}
$receipt = [ordered]@{
    schemaVersion = 1
    component = 'public-windows-mcp-stdio-frame-canary'
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    runtime = $runtime
    expectedProtocolVersion = '2026-07-28'
    request = [ordered]@{
        method = 'tools/call'
        rawProtocolToolName = 'search'
        requiredRequestMetaPresent = $true
        bodyUtf8ByteLength = $bodyBytes.Length
        bodySha256 = $bodySha256
        frameByteLength = $frameBytes.Length
        frameSha256 = $frameSha256
    }
    acceptance = [ordered]@{
        exactExpectedJsonAccepted = $true
        exactExpectedBodySha256Accepted = $true
        exactExpectedFrameSha256Accepted = $true
        utf8Accepted = $true
        exactlyOneTrailingLfAccepted = $true
        noEmbeddedLfBytesAccepted = $true
        noCarriageReturnBytesAccepted = $true
        utf8BomAbsentAccepted = $true
        transportWriteObserved = $false
        mcpServerExecutionAccepted = $false
        semanticToolAccepted = $false
    }
}

$directory = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutputPath), ($receipt | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "MCP_STDIO_FRAME_CANARY_PASS body=$bodySha256 frame=$frameSha256"
