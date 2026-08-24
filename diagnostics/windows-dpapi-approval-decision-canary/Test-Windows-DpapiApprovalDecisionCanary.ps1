param(
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

Assert-True ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) 'DPAPI approval-decision canary requires native Windows.'
Assert-True ($env:RUNNER_OS -eq 'Windows') 'GitHub runner context must report Windows.'

$decision = [ordered]@{
    schemaVersion = 1
    approvalRequestId = '11111111-2222-3333-4444-555555555555'
    toolCallId = 'canary-tool-call-1'
    approvalSubjectCanonicalSha256 = ('ab' * 32)
    approved = $true
    reason = 'diagnostic-only'
}
$decisionJson = $decision | ConvertTo-Json -Compress -Depth 10
$plainBytes = [System.Text.Encoding]::UTF8.GetBytes($decisionJson)
$entropy = [System.Text.Encoding]::UTF8.GetBytes('braintrust:mcp-multiserver-approval-decision:v1:2026-07-28:stdio')

$protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
    $plainBytes,
    $entropy,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
)
Assert-True ($protectedBytes.Length -gt 0) 'DPAPI returned an empty protected blob.'

$unprotectedBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
    $protectedBytes,
    $entropy,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
)
Assert-True ($unprotectedBytes.Length -eq $plainBytes.Length) 'DPAPI round-trip byte length differs.'
for ($i = 0; $i -lt $plainBytes.Length; $i++) {
    if ($plainBytes[$i] -ne $unprotectedBytes[$i]) {
        throw "DPAPI round-trip byte mismatch at offset $i."
    }
}

$tamperedBytes = New-Object byte[] $protectedBytes.Length
[Array]::Copy($protectedBytes, $tamperedBytes, $protectedBytes.Length)
$tamperIndex = [Math]::Max(0, [Math]::Floor($tamperedBytes.Length / 2))
$tamperedBytes[$tamperIndex] = $tamperedBytes[$tamperIndex] -bxor 0x01
$tamperRejected = $false
try {
    $unexpectedPlaintext = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $tamperedBytes,
        $entropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$unexpectedPlaintext, [byte[]]$plainBytes)) {
        $tamperRejected = $true
    }
} catch [System.Security.Cryptography.CryptographicException] {
    $tamperRejected = $true
}
Assert-True $tamperRejected 'Tampered CurrentUser DPAPI blob was not rejected or changed on unprotect.'

$output = [ordered]@{
    schemaVersion = 1
    component = 'public-windows-dpapi-approval-decision-canary'
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    environment = [ordered]@{
        runnerOs = $env:RUNNER_OS
        runnerArch = $env:RUNNER_ARCH
        osDescription = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        psEdition = $PSVersionTable.PSEdition
        psVersion = $PSVersionTable.PSVersion.ToString()
    }
    dpapi = [ordered]@{
        scope = 'CurrentUser'
        currentUserScopeRoundTripAccepted = $true
        tamperedBlobRejected = $true
        plaintextSha256 = Get-BytesSha256 $plainBytes
        protectedBlobSha256 = Get-BytesSha256 $protectedBytes
        plaintextByteLength = $plainBytes.Length
        protectedBlobByteLength = $protectedBytes.Length
        additionalEntropyDomainSeparated = $true
    }
    acceptanceBoundary = [ordered]@{
        currentUserDpapiPrimitiveAccepted = $true
        sameCurrentUserContextRequiredForUnprotect = $true
        decisionOriginAuthenticated = $false
        approverIdentityAccepted = $false
        humanPresenceAccepted = $false
        toolExecutionAuthorized = $false
        privateBraintrustApprovalPipelineAccepted = $false
        windowsFinalStateAccepted = $false
    }
}

$outputDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
if ($outputDirectory) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutputPath), ($output | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "DPAPI approval-decision canary PASS: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion) / $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
