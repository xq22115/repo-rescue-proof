param(
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$TargetProcess,
    [Parameter(Mandatory = $true)][string]$StdioSessionAffinityReceiptPath,
    [Parameter(Mandatory = $true)][string]$ExpectedStdioSessionAffinityReceiptSha256,
    [Parameter(Mandatory = $true)][string]$NearWireRevalidationReceiptPath,
    [Parameter(Mandatory = $true)][string]$ExpectedNearWireRevalidationReceiptSha256,
    [Parameter(Mandatory = $true)][string]$FramePlanReceiptPath,
    [Parameter(Mandatory = $true)][string]$ExpectedFramePlanReceiptSha256,
    [Parameter(Mandatory = $true)][string]$ChildWriteAttemptReceiptPath,
    [Parameter(Mandatory = $true)][string]$NearWireWriteReceiptPath,
    [Parameter(Mandatory = $true)][string]$ReceiptPath,
    [ValidateRange(100, 30000)][int]$WriteTimeoutMs = 5000,
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

if ($env:BRAINTRUST_SINGLE_FLIGHT_DIAGNOSTIC_WRITE_MODE -eq 'fail-after-lease') {
    throw 'DIAGNOSTIC_WRITE_FAILURE_AFTER_SINGLE_FLIGHT_LEASE'
}

$holdMs = 0
if (-not [string]::IsNullOrWhiteSpace($env:BRAINTRUST_SINGLE_FLIGHT_DIAGNOSTIC_HOLD_MS)) {
    [void][int]::TryParse($env:BRAINTRUST_SINGLE_FLIGHT_DIAGNOSTIC_HOLD_MS, [ref]$holdMs)
}
if ($holdMs -gt 0) { Start-Sleep -Milliseconds $holdMs }

Write-DiagnosticJson $ChildWriteAttemptReceiptPath ([ordered]@{
    schemaVersion = 1
    component = 'diagnostic-child-write-attempt'
    processId = [int]$TargetProcess.Id
    holdMilliseconds = $holdMs
})
Write-DiagnosticJson $NearWireWriteReceiptPath ([ordered]@{
    schemaVersion = 1
    component = 'diagnostic-near-wire-write-attempt'
    processId = [int]$TargetProcess.Id
})
Write-DiagnosticJson $ReceiptPath ([ordered]@{
    schemaVersion = 1
    component = 'diagnostic-process-owned-write-attempt'
    processId = [int]$TargetProcess.Id
    diagnosticOnly = $true
})
