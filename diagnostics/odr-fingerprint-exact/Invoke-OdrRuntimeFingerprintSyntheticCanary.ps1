param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('odr-fingerprint-exact-' + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

try {
    $deploymentPath = Join-Path $temp 'deployment.json'
    $fingerprintPath = Join-Path $temp 'fingerprint.json'
    $syntheticOdrPath = 'C:\Windows\System32\odr.exe'
    $syntheticSha = 'abababababababababababababababababababababababababababababababab'

    [ordered]@{
        component = 'windows-mcp-deployment-profile'
        selectionAccepted = $true
        selectedProfile = 'odr-msix-contained'
        odr = [ordered]@{
            executablePresent = $true
            executablePath = $syntheticOdrPath
        }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $deploymentPath -Encoding UTF8

    $fingerprint = & (Join-Path $PSScriptRoot 'Get-Windows-Mcp-OdrRuntimeFingerprint.ps1') `
        -DeploymentProfileReceiptPath $deploymentPath `
        -ReceiptPath $fingerprintPath `
        -SkipPlatformCheck `
        -OverrideOdrExecutablePath $syntheticOdrPath `
        -OverrideOdrSha256 $syntheticSha `
        -OverrideSignatureStatus 'Valid' `
        -OverrideSignerSubject 'CN=Microsoft Corporation' `
        -OverrideSignerIssuer 'CN=Microsoft Code Signing PCA' `
        -OverrideSignerThumbprint '00112233445566778899AABBCCDDEEFF00112233' `
        -OverrideFileVersion '10.0.26220.9999' `
        -OverrideProductVersion '10.0.26220.9999' `
        -OverrideVersionOutput 'odr 10.0.26220.9999' `
        -OverrideVersionExitCode 0

    if ($fingerprint.runtimeFingerprintAccepted -ne $true) {
        throw 'Corrected exact production ODR runtime-fingerprint script did not accept the synthetic valid fingerprint.'
    }
    if ([int]$fingerprint.versionProbe.exitCode -ne 0) {
        throw 'Synthetic version exit code was not preserved as integer zero.'
    }
    if ($fingerprint.acceptanceBoundary.protocolRuntimeAccepted -ne $false) {
        throw 'Synthetic fingerprint overclaimed protocol runtime acceptance.'
    }

    $scriptPath = Join-Path $PSScriptRoot 'Get-Windows-Mcp-OdrRuntimeFingerprint.ps1'
    $scriptSha = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $scriptBytes = [System.IO.File]::ReadAllBytes($scriptPath).Length

    $receipt = [ordered]@{
        schemaVersion = 1
        component = 'diagnostic-odr-runtime-fingerprint-synthetic-native'
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        psEdition = [string]$PSVersionTable.PSEdition
        psVersion = [string]$PSVersionTable.PSVersion
        frameworkDescription = [string][System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        productionScriptSha256 = $scriptSha
        productionScriptByteLength = $scriptBytes
        runtimeFingerprintAccepted = [bool]$fingerprint.runtimeFingerprintAccepted
        syntheticVersionExitCode = [int]$fingerprint.versionProbe.exitCode
        acceptance = [ordered]@{
            correctedProductionScriptNativeSyntheticPathAccepted = $true
            nullableValueMemberAccessAcceptedAsPortableContract = $false
            productionIdentityVerified = $false
            odrRuntimeLiveAcceptance = $false
            protocolRuntimeAccepted = $false
            semanticToolAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }

    $directory = Split-Path -Parent $OutputPath
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host ("ODR runtime fingerprint exact synthetic canary: PASS ({0} {1}, sha256={2})" -f $receipt.psEdition, $receipt.psVersion, $scriptSha)
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
