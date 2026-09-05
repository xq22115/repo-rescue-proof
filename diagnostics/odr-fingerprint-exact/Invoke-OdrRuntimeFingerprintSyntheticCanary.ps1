param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Throws([scriptblock]$Script, [string]$Message) {
    $threw = $false
    try { & $Script } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

function Write-DeploymentReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Build = 26220,
        [int]$Ubr = 7262,
        [object]$BuildEligible = $true,
        [object]$ExecutablePresent = $true,
        [object]$BaseEligible = $true,
        [object]$PrerequisiteEligible = $true,
        [string]$PrerequisiteStatus = 'build-eligible-odr-present',
        [int]$MinimumBuild = 26220,
        [int]$MinimumUbr = 7262
    )

    $syntheticOdrPath = 'C:\Windows\System32\odr.exe'
    [ordered]@{
        schemaVersion = 2
        component = 'windows-mcp-deployment-profile'
        requestedProfile = 'odr-msix-contained'
        selectedProfile = 'odr-msix-contained'
        selectionAccepted = $true
        selectionReason = 'synthetic diagnostic only'
        previewFeatureRequired = $true
        previewOdrExplicitlyAllowed = $true
        reducedProtectionRequired = $false
        reducedProtectionExplicitlyAllowed = $false
        containmentExpected = $true
        productionPlatformCheckSkipped = $true
        preflightSideEffects = [ordered]@{
            mode = 'read-only'
            modifiesDeveloperMode = $false
            modifiesReducedProtections = $false
            installsDotnet = $false
            installsMcpbCli = $false
            registersMcpServer = $false
        }
        windows = [ordered]@{
            productName = 'synthetic-windows'
            displayVersion = 'synthetic'
            editionId = 'synthetic'
            buildNumber = $Build
            ubr = $Ubr
        }
        odr = [ordered]@{
            documentedMinimumBuild = "${MinimumBuild}.${MinimumUbr}"
            documentedMinimumBuildNumber = $MinimumBuild
            documentedMinimumUbr = $MinimumUbr
            buildEligible = $BuildEligible
            executablePresent = $ExecutablePresent
            executablePath = $syntheticOdrPath
            baseEligible = $BaseEligible
            prerequisiteEligible = $PrerequisiteEligible
            prerequisiteStatus = $PrerequisiteStatus
            containedMsixEligible = $BaseEligible
        }
        mcpBundle = [ordered]@{
            developerModeEnabled = $false
            dotnetPresent = $false
            mcpbCliPresent = $false
            toolingEligible = $false
            containmentAvailable = $false
        }
        acceptanceBoundary = [ordered]@{
            deploymentProfileAccepted = $true
            odrPrerequisiteObservationAccepted = $true
            productionOdrPrerequisiteObservationAccepted = $false
            odrRuntimeAccepted = $false
            packageIdentityAccepted = $false
            executableIdentityAccepted = $false
            lifecycleRuntimeAccepted = $false
            protocolRuntimeAccepted = $false
            semanticToolAccepted = $false
            osStateReadbackAccepted = $false
        }
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-SyntheticFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$DeploymentPath,
        [Parameter(Mandatory = $true)][string]$ReceiptPath
    )

    return & (Join-Path $PSScriptRoot 'Get-Windows-Mcp-OdrRuntimeFingerprint.ps1') `
        -DeploymentProfileReceiptPath $DeploymentPath `
        -ReceiptPath $ReceiptPath `
        -SkipPlatformCheck `
        -OverrideOdrExecutablePath 'C:\Windows\System32\odr.exe' `
        -OverrideOdrSha256 'abababababababababababababababababababababababababababababababab' `
        -OverrideSignatureStatus 'Valid' `
        -OverrideSignerSubject 'CN=Microsoft Corporation' `
        -OverrideSignerIssuer 'CN=Microsoft Code Signing PCA' `
        -OverrideSignerThumbprint '00112233445566778899AABBCCDDEEFF00112233' `
        -OverrideFileVersion '10.0.26220.9999' `
        -OverrideProductVersion '10.0.26220.9999' `
        -OverrideVersionOutput 'odr 10.0.26220.9999' `
        -OverrideVersionExitCode 0
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('odr-fingerprint-exact-' + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

try {
    $deploymentPath = Join-Path $temp 'deployment.json'
    $fingerprintPath = Join-Path $temp 'fingerprint.json'
    Write-DeploymentReceipt -Path $deploymentPath

    $fingerprint = Invoke-SyntheticFingerprint -DeploymentPath $deploymentPath -ReceiptPath $fingerprintPath
    if ($fingerprint.schemaVersion -ne 3) { throw 'Corrected production ODR fingerprint did not emit schema 3.' }
    if ($fingerprint.runtimeFingerprintAccepted -ne $true) { throw 'Corrected production ODR runtime-fingerprint script did not accept the synthetic valid fingerprint.' }
    if ([int]$fingerprint.versionProbe.exitCode -ne 0) { throw 'Synthetic version exit code was not preserved as integer zero.' }
    if ($fingerprint.prerequisiteBinding.prerequisiteStatus -ne 'build-eligible-odr-present') { throw 'Prerequisite status was not bound into the fingerprint.' }
    if ($fingerprint.prerequisiteBinding.recomputedBuildEligible -ne $true) { throw 'Build eligibility was not recomputed.' }
    if ($fingerprint.acceptanceBoundary.odrPrerequisiteAccepted -ne $true) { throw 'Fingerprint did not record prerequisite acceptance.' }
    if ($fingerprint.acceptanceBoundary.protocolRuntimeAccepted -ne $false) { throw 'Synthetic fingerprint overclaimed protocol runtime acceptance.' }

    $lowBuildPath = Join-Path $temp 'low-build-lie.json'
    Write-DeploymentReceipt -Path $lowBuildPath -Build 26100 -Ubr 33296 -BuildEligible $true -ExecutablePresent $true -BaseEligible $true -PrerequisiteEligible $true -PrerequisiteStatus 'build-eligible-odr-present'
    Assert-Throws {
        Invoke-SyntheticFingerprint -DeploymentPath $lowBuildPath -ReceiptPath (Join-Path $temp 'low-build-fingerprint.json') | Out-Null
    } 'Production fingerprint trusted a forged buildEligible=true on an ineligible Windows build.'

    $missingOdrPath = Join-Path $temp 'missing-odr.json'
    Write-DeploymentReceipt -Path $missingOdrPath -ExecutablePresent $false -BaseEligible $false -PrerequisiteEligible $false -PrerequisiteStatus 'build-eligible-odr-missing'
    Assert-Throws {
        Invoke-SyntheticFingerprint -DeploymentPath $missingOdrPath -ReceiptPath (Join-Path $temp 'missing-odr-fingerprint.json') | Out-Null
    } 'Production fingerprint accepted build-eligible-odr-missing.'

    $stringBooleanPath = Join-Path $temp 'string-boolean.json'
    Write-DeploymentReceipt -Path $stringBooleanPath -BuildEligible 'true'
    Assert-Throws {
        Invoke-SyntheticFingerprint -DeploymentPath $stringBooleanPath -ReceiptPath (Join-Path $temp 'string-boolean-fingerprint.json') | Out-Null
    } 'Production fingerprint coerced string buildEligible into a boolean.'

    $minimumDriftPath = Join-Path $temp 'minimum-drift.json'
    Write-DeploymentReceipt -Path $minimumDriftPath -MinimumBuild 26200 -MinimumUbr 0
    Assert-Throws {
        Invoke-SyntheticFingerprint -DeploymentPath $minimumDriftPath -ReceiptPath (Join-Path $temp 'minimum-drift-fingerprint.json') | Out-Null
    } 'Production fingerprint accepted a stale ODR minimum-build contract.'

    $scriptPath = Join-Path $PSScriptRoot 'Get-Windows-Mcp-OdrRuntimeFingerprint.ps1'
    $scriptSha = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $scriptBytes = [System.IO.File]::ReadAllBytes($scriptPath).Length

    $receipt = [ordered]@{
        schemaVersion = 2
        component = 'diagnostic-odr-runtime-fingerprint-prerequisite-binding-native'
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        psEdition = [string]$PSVersionTable.PSEdition
        psVersion = [string]$PSVersionTable.PSVersion
        frameworkDescription = [string][System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        productionScriptSha256 = $scriptSha
        productionScriptByteLength = $scriptBytes
        fingerprintSchemaVersion = [int]$fingerprint.schemaVersion
        prerequisiteStatus = [string]$fingerprint.prerequisiteBinding.prerequisiteStatus
        prerequisiteEligible = [bool]$fingerprint.prerequisiteBinding.prerequisiteEligible
        recomputedBuildEligible = [bool]$fingerprint.prerequisiteBinding.recomputedBuildEligible
        acceptance = [ordered]@{
            exactProductionFingerprintNativeSyntheticPathAccepted = $true
            forgedLowBuildEligibilityRejected = $true
            missingOdrRejected = $true
            stringBooleanCoercionRejected = $true
            minimumContractDriftRejected = $true
            liveOdrExecutableObserved = $false
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
    Write-Host ("ODR prerequisite-bound runtime fingerprint canary: PASS ({0} {1}, sha256={2})" -f $receipt.psEdition, $receipt.psVersion, $scriptSha)
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
