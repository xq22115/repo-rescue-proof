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

function Write-DiagnosticJson([string]$Path, [object]$Value) {
    $full = [IO.Path]::GetFullPath($Path)
    $dir = Split-Path -Parent $full
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($full, ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}

$frame = (Get-Content -LiteralPath $FramePlanReceiptPath -Raw) | ConvertFrom-Json -ErrorAction Stop
$requestId = $null
if ($null -ne $frame.PSObject.Properties['requestBinding']) {
    $requestId = [string]$frame.requestBinding.requestId
} elseif ($null -ne $frame.PSObject.Properties['requestId']) {
    $requestId = [string]$frame.requestId
}
if ([string]::IsNullOrWhiteSpace($requestId)) { throw 'Diagnostic frame plan did not contain a request id.' }

$response = [ordered]@{
    jsonrpc = '2.0'
    id = $requestId
    result = [ordered]@{ diagnostic = $true }
}
Write-DiagnosticJson $ResponseArtifactPath $response
Write-DiagnosticJson $ReceiptPath ([ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-process-owned-stdio-response-capture'
    diagnosticOnly = $true
    processId = [int]$TargetProcess.Id
    requestResponseBinding = [ordered]@{
        requestId = $requestId
        responseId = $requestId
    }
})
