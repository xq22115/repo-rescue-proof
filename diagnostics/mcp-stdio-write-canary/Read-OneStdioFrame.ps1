param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidateRange(1, 4194304)][int]$MaxBytes = 1048576
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

$stream = [Console]::OpenStandardInput()
$memory = New-Object System.IO.MemoryStream
$buffer = New-Object byte[] 1
try {
    while ($true) {
        $count = $stream.Read($buffer, 0, 1)
        if ($count -eq 0) { throw 'stdin closed before an LF-delimited frame was complete.' }
        $memory.WriteByte($buffer[0])
        if ($memory.Length -gt $MaxBytes) { throw "stdio frame exceeded ${MaxBytes} bytes." }
        if ($buffer[0] -eq 0x0A) { break }
    }

    [byte[]]$frameBytes = $memory.ToArray()
    if ($frameBytes.Length -lt 2) { throw 'stdio frame was unexpectedly short.' }
    if ($frameBytes[$frameBytes.Length - 1] -ne 0x0A) { throw 'stdio frame did not end in LF.' }
    if (@($frameBytes | Where-Object { $_ -eq 0x0A }).Count -ne 1) { throw 'stdio frame contained more than one LF byte.' }
    if (@($frameBytes | Where-Object { $_ -eq 0x0D }).Count -ne 0) { throw 'stdio frame contained a CR byte.' }
    if ($frameBytes.Length -ge 3 -and $frameBytes[0] -eq 0xEF -and $frameBytes[1] -eq 0xBB -and $frameBytes[2] -eq 0xBF) { throw 'stdio frame contained a UTF-8 BOM.' }

    [byte[]]$bodyBytes = New-Object byte[] ($frameBytes.Length - 1)
    [System.Buffer]::BlockCopy($frameBytes, 0, $bodyBytes, 0, $bodyBytes.Length)
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $bodyText = $utf8.GetString($bodyBytes)
    } catch {
        throw 'stdio frame body was not strict UTF-8.'
    }
    try {
        $message = $bodyText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "stdio frame body was not JSON: $($_.Exception.Message)"
    }
    if ([string]$message.jsonrpc -ne '2.0') { throw 'JSON-RPC version was not 2.0.' }
    if ([string]$message.method -ne 'tools/call') { throw 'JSON-RPC method was not tools/call.' }

    $receipt = [ordered]@{
        schemaVersion = 1
        component = 'public-windows-mcp-stdio-child-frame-read'
        generatedAtUtc = [datetime]::UtcNow.ToString('o')
        runtime = [ordered]@{
            osDescription = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
            osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
            frameworkDescription = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
            psEdition = $PSVersionTable.PSEdition
            psVersion = $PSVersionTable.PSVersion.ToString()
        }
        frame = [ordered]@{
            byteLength = $frameBytes.Length
            sha256 = Get-Sha256 $frameBytes
            bodyByteLength = $bodyBytes.Length
            bodySha256 = Get-Sha256 $bodyBytes
            strictUtf8Accepted = $true
            exactlyOneTrailingLfAccepted = $true
            noCarriageReturnBytesAccepted = $true
            utf8BomAbsentAccepted = $true
            jsonRpcToolsCallShapeAccepted = $true
        }
        acceptance = [ordered]@{
            childStdioFrameReadAccepted = $true
            mcpServerExecutionAccepted = $false
            toolExecutionAccepted = $false
            semanticToolAccepted = $false
        }
    }

    $fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $directory = Split-Path -Parent $fullOutputPath
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($fullOutputPath, ($receipt | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "MCP_STDIO_CHILD_FRAME_READ_PASS sha256=$($receipt.frame.sha256) bytes=$($receipt.frame.byteLength)"
} finally {
    $memory.Dispose()
}
