param(
    [Parameter(Mandatory = $true)]
    [string]$DeploymentProfileReceiptPath,

    [Parameter(Mandatory = $true)]
    [string]$ReceiptPath,

    [switch]$SkipPlatformCheck,

    [string]$OverrideOdrExecutablePath,
    [string]$OverrideOdrSha256,
    [string]$OverrideSignatureStatus,
    [string]$OverrideSignerSubject,
    [string]$OverrideSignerIssuer,
    [string]$OverrideSignerThumbprint,
    [string]$OverrideFileVersion,
    [string]$OverrideProductVersion,
    [string]$OverrideVersionOutput,
    [Nullable[int]]$OverrideVersionExitCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Get-BraintrustStrictJsonScalar.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-BuildAtLeast([int]$Build, [int]$Ubr, [int]$MinimumBuild, [int]$MinimumUbr) {
    if ($Build -gt $MinimumBuild) { return $true }
    if ($Build -lt $MinimumBuild) { return $false }
    return ($Ubr -ge $MinimumUbr)
}

function Test-OverrideSupplied {
    return (
        -not [string]::IsNullOrWhiteSpace($OverrideOdrExecutablePath) -or
        -not [string]::IsNullOrWhiteSpace($OverrideOdrSha256) -or
        -not [string]::IsNullOrWhiteSpace($OverrideSignatureStatus) -or
        -not [string]::IsNullOrWhiteSpace($OverrideSignerSubject) -or
        -not [string]::IsNullOrWhiteSpace($OverrideSignerIssuer) -or
        -not [string]::IsNullOrWhiteSpace($OverrideSignerThumbprint) -or
        -not [string]::IsNullOrWhiteSpace($OverrideFileVersion) -or
        -not [string]::IsNullOrWhiteSpace($OverrideProductVersion) -or
        -not [string]::IsNullOrWhiteSpace($OverrideVersionOutput) -or
        $null -ne $OverrideVersionExitCode
    )
}

function Invoke-OdrVersionProbe([string]$ExecutablePath, [int]$TimeoutMs = 5000) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ExecutablePath
    $startInfo.Arguments = '--version'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        Assert-True ($process.Start()) "Failed to start '$ExecutablePath --version'."
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill() } catch {}
            throw "Timed out after ${TimeoutMs}ms while running '$ExecutablePath --version'."
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()

        return [ordered]@{
            exitCode = [int]$process.ExitCode
            stdout = [string]$stdout
            stderr = [string]$stderr
        }
    } finally {
        $process.Dispose()
    }
}

$minimumOdrBuild = 26220
$minimumOdrUbr = 7262

Assert-True (Test-Path -LiteralPath $DeploymentProfileReceiptPath -PathType Leaf) 'Deployment profile receipt was not found.'

$overrideSupplied = Test-OverrideSupplied
if ($overrideSupplied -and -not $SkipPlatformCheck) {
    throw 'Synthetic ODR runtime-fingerprint overrides are test-only and require -SkipPlatformCheck.'
}
if (-not $SkipPlatformCheck) {
    Assert-True ($env:OS -eq 'Windows_NT') 'Get-Windows-Mcp-OdrRuntimeFingerprint.ps1 only supports Windows in production mode.'
}

$deploymentRaw = Get-Content -LiteralPath $DeploymentProfileReceiptPath -Raw
$deployment = $deploymentRaw | ConvertFrom-Json
$deploymentSchemaVersion = [int](Get-BraintrustRequiredJsonInteger -Object $deployment -Name 'schemaVersion' -FieldName 'deployment.schemaVersion')
Assert-True ($deploymentSchemaVersion -eq 2) "ODR runtime fingerprint requires deployment-profile schema 2; received schema $deploymentSchemaVersion."
$deploymentComponent = Get-BraintrustRequiredJsonString -Object $deployment -Name 'component' -FieldName 'deployment.component'
Assert-True ($deploymentComponent -eq 'windows-mcp-deployment-profile') 'Input deployment receipt is not a Windows MCP deployment-profile receipt.'
$selectionAccepted = Get-BraintrustRequiredJsonBoolean -Object $deployment -Name 'selectionAccepted' -FieldName 'deployment.selectionAccepted'
Assert-True $selectionAccepted 'Deployment profile was not accepted.'
$deploymentPlatformCheckSkipped = Get-BraintrustRequiredJsonBoolean -Object $deployment -Name 'productionPlatformCheckSkipped' -FieldName 'deployment.productionPlatformCheckSkipped'
Assert-True ($deploymentPlatformCheckSkipped -eq [bool]$SkipPlatformCheck) 'Deployment receipt platform-observation mode did not match the runtime-fingerprint mode.'

$selectedProfile = Get-BraintrustRequiredJsonString -Object $deployment -Name 'selectedProfile' -FieldName 'deployment.selectedProfile'
Assert-True (@('odr-msix-contained', 'mcpb-preview') -contains $selectedProfile) "ODR runtime fingerprint requires an ODR-backed deployment profile; selected profile was '$selectedProfile'."

$windows = Get-BraintrustRequiredJsonObject -Object $deployment -Name 'windows' -FieldName 'deployment.windows'
$buildNumber = [int](Get-BraintrustRequiredJsonInteger -Object $windows -Name 'buildNumber' -FieldName 'deployment.windows.buildNumber')
$ubr = [int](Get-BraintrustRequiredJsonInteger -Object $windows -Name 'ubr' -FieldName 'deployment.windows.ubr')

$odr = Get-BraintrustRequiredJsonObject -Object $deployment -Name 'odr' -FieldName 'deployment.odr'
$documentedMinimumBuild = Get-BraintrustRequiredJsonString -Object $odr -Name 'documentedMinimumBuild' -FieldName 'deployment.odr.documentedMinimumBuild'
$documentedMinimumBuildNumber = [int](Get-BraintrustRequiredJsonInteger -Object $odr -Name 'documentedMinimumBuildNumber' -FieldName 'deployment.odr.documentedMinimumBuildNumber')
$documentedMinimumUbr = [int](Get-BraintrustRequiredJsonInteger -Object $odr -Name 'documentedMinimumUbr' -FieldName 'deployment.odr.documentedMinimumUbr')
Assert-True ($documentedMinimumBuildNumber -eq $minimumOdrBuild) "Deployment receipt used unexpected ODR minimum build '$documentedMinimumBuildNumber'."
Assert-True ($documentedMinimumUbr -eq $minimumOdrUbr) "Deployment receipt used unexpected ODR minimum UBR '$documentedMinimumUbr'."
Assert-True ($documentedMinimumBuild -eq "${minimumOdrBuild}.${minimumOdrUbr}") "Deployment receipt used inconsistent ODR minimum build text '$documentedMinimumBuild'."

$odrBuildEligible = Get-BraintrustRequiredJsonBoolean -Object $odr -Name 'buildEligible' -FieldName 'deployment.odr.buildEligible'
$odrPresent = Get-BraintrustRequiredJsonBoolean -Object $odr -Name 'executablePresent' -FieldName 'deployment.odr.executablePresent'
$odrBaseEligible = Get-BraintrustRequiredJsonBoolean -Object $odr -Name 'baseEligible' -FieldName 'deployment.odr.baseEligible'
$odrPrerequisiteEligible = Get-BraintrustRequiredJsonBoolean -Object $odr -Name 'prerequisiteEligible' -FieldName 'deployment.odr.prerequisiteEligible'
$odrPrerequisiteStatus = Get-BraintrustRequiredJsonString -Object $odr -Name 'prerequisiteStatus' -FieldName 'deployment.odr.prerequisiteStatus'
$deploymentOdrPath = Get-BraintrustRequiredJsonString -Object $odr -Name 'executablePath' -FieldName 'deployment.odr.executablePath'

$recomputedBuildEligible = Test-BuildAtLeast -Build $buildNumber -Ubr $ubr -MinimumBuild $minimumOdrBuild -MinimumUbr $minimumOdrUbr
Assert-True ($odrBuildEligible -eq $recomputedBuildEligible) 'Deployment receipt ODR buildEligible did not match the observed build/UBR and documented minimum.'
Assert-True $odrBuildEligible 'ODR runtime fingerprint requires an ODR build-eligible deployment receipt.'
Assert-True $odrPresent 'Deployment receipt did not record odr.exe as present.'
Assert-True $odrBaseEligible 'Deployment receipt did not record the ODR base prerequisite as eligible.'
Assert-True $odrPrerequisiteEligible 'Deployment receipt did not record the combined ODR prerequisite as eligible.'
Assert-True ($odrPrerequisiteStatus -eq 'build-eligible-odr-present') "ODR runtime fingerprint requires prerequisiteStatus=build-eligible-odr-present; received '$odrPrerequisiteStatus'."
Assert-True ([System.IO.Path]::IsPathRooted($deploymentOdrPath)) 'Deployment receipt odr.exe path must be absolute.'

$deploymentBoundary = Get-BraintrustRequiredJsonObject -Object $deployment -Name 'acceptanceBoundary' -FieldName 'deployment.acceptanceBoundary'
$deploymentProfileAccepted = Get-BraintrustRequiredJsonBoolean -Object $deploymentBoundary -Name 'deploymentProfileAccepted' -FieldName 'deployment.acceptanceBoundary.deploymentProfileAccepted'
$odrPrerequisiteObservationAccepted = Get-BraintrustRequiredJsonBoolean -Object $deploymentBoundary -Name 'odrPrerequisiteObservationAccepted' -FieldName 'deployment.acceptanceBoundary.odrPrerequisiteObservationAccepted'
$productionOdrPrerequisiteObservationAccepted = Get-BraintrustRequiredJsonBoolean -Object $deploymentBoundary -Name 'productionOdrPrerequisiteObservationAccepted' -FieldName 'deployment.acceptanceBoundary.productionOdrPrerequisiteObservationAccepted'
Assert-True $deploymentProfileAccepted 'Deployment acceptance boundary did not accept the deployment profile.'
Assert-True $odrPrerequisiteObservationAccepted 'Deployment acceptance boundary did not accept ODR prerequisite observation.'
if (-not $SkipPlatformCheck) {
    Assert-True $productionOdrPrerequisiteObservationAccepted 'Production ODR runtime fingerprint requires a production prerequisite observation.'
}

$deploymentHash = Get-FileSha256 $DeploymentProfileReceiptPath

$resolvedOdrPath = $null
$odrSha256 = $null
$signatureStatus = $null
$signerSubject = $null
$signerIssuer = $null
$signerThumbprint = $null
$fileVersion = $null
$productVersion = $null
$versionProbe = $null
$productionIdentityVerified = $false

if ($SkipPlatformCheck) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($OverrideOdrExecutablePath)) 'Test mode requires -OverrideOdrExecutablePath.'
    Assert-True ([System.IO.Path]::IsPathRooted($OverrideOdrExecutablePath)) 'Synthetic ODR executable path must be absolute.'
    Assert-True ($OverrideOdrExecutablePath -eq $deploymentOdrPath) 'Synthetic ODR executable path must match the deployment-profile receipt.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($OverrideOdrSha256)) 'Test mode requires -OverrideOdrSha256.'
    Assert-True ($OverrideOdrSha256 -match '^[0-9a-fA-F]{64}$') 'Synthetic ODR SHA-256 must be 64 hexadecimal characters.'
    Assert-True ($OverrideSignatureStatus -eq 'Valid') 'Test mode requires OverrideSignatureStatus=Valid.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($OverrideSignerSubject)) 'Test mode requires -OverrideSignerSubject.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($OverrideSignerThumbprint)) 'Test mode requires -OverrideSignerThumbprint.'
    Assert-True ($null -ne $OverrideVersionExitCode) 'Test mode requires -OverrideVersionExitCode.'

    # Nullable[T] parameters box non-null values as their underlying scalar on both
    # Windows PowerShell 5.1 and PowerShell 7. After the null check, cast directly;
    # dereferencing .Value is not a portable PowerShell contract.
    $syntheticVersionExitCode = [int]$OverrideVersionExitCode
    Assert-True ($syntheticVersionExitCode -eq 0) 'Synthetic odr.exe --version probe must exit 0.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($OverrideVersionOutput)) 'Synthetic odr.exe --version output must not be empty.'

    $resolvedOdrPath = $OverrideOdrExecutablePath
    $odrSha256 = $OverrideOdrSha256.ToLowerInvariant()
    $signatureStatus = $OverrideSignatureStatus
    $signerSubject = $OverrideSignerSubject
    $signerIssuer = $OverrideSignerIssuer
    $signerThumbprint = $OverrideSignerThumbprint
    $fileVersion = $OverrideFileVersion
    $productVersion = $OverrideProductVersion
    $versionProbe = [ordered]@{
        exitCode = $syntheticVersionExitCode
        stdout = $OverrideVersionOutput
        stderr = ''
    }
} else {
    Assert-True (Test-Path -LiteralPath $deploymentOdrPath -PathType Leaf) "Deployment-profile odr.exe path does not exist as a file: $deploymentOdrPath"
    $resolvedOdrPath = (Resolve-Path -LiteralPath $deploymentOdrPath).Path
    Assert-True ([System.IO.Path]::GetExtension($resolvedOdrPath).Equals('.exe', [System.StringComparison]::OrdinalIgnoreCase)) 'Resolved ODR runtime must be an .exe file.'

    $odrSha256 = Get-FileSha256 $resolvedOdrPath

    $signature = Get-AuthenticodeSignature -LiteralPath $resolvedOdrPath
    $signatureStatus = [string]$signature.Status
    Assert-True ($signatureStatus -eq 'Valid') "odr.exe Authenticode signature was '$signatureStatus', not Valid."
    Assert-True ($null -ne $signature.SignerCertificate) 'odr.exe did not expose a signer certificate.'

    $signerSubject = [string]$signature.SignerCertificate.Subject
    $signerIssuer = [string]$signature.SignerCertificate.Issuer
    $signerThumbprint = [string]$signature.SignerCertificate.Thumbprint

    $versionInfo = (Get-Item -LiteralPath $resolvedOdrPath).VersionInfo
    $fileVersion = [string]$versionInfo.FileVersion
    $productVersion = [string]$versionInfo.ProductVersion

    $versionProbe = Invoke-OdrVersionProbe -ExecutablePath $resolvedOdrPath
    Assert-True ([int]$versionProbe.exitCode -eq 0) "odr.exe --version exited with code $($versionProbe.exitCode)."
    $versionText = (([string]$versionProbe.stdout) + "`n" + ([string]$versionProbe.stderr)).Trim()
    Assert-True (-not [string]::IsNullOrWhiteSpace($versionText)) 'odr.exe --version produced no version text.'

    $productionIdentityVerified = $true
}

$versionText = (([string]$versionProbe.stdout) + "`n" + ([string]$versionProbe.stderr)).Trim()

$receiptDirectory = Split-Path -Parent $ReceiptPath
if ($receiptDirectory) { New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null }

$receipt = [ordered]@{
    schemaVersion = 3
    component = 'windows-mcp-odr-runtime-fingerprint'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    strictUpstreamReceiptBooleanTypesValidated = $true
    strictUpstreamReceiptStringAndIntegerTypesValidated = $true
    stringOrNumericBooleanCoercionAllowed = $false
    selectedProfile = $selectedProfile
    deploymentProfile = [ordered]@{
        path = $DeploymentProfileReceiptPath
        receiptSha256 = $deploymentHash
        schemaVersion = $deploymentSchemaVersion
        productionPlatformCheckSkipped = $deploymentPlatformCheckSkipped
    }
    prerequisiteBinding = [ordered]@{
        documentedMinimumBuild = $documentedMinimumBuild
        documentedMinimumBuildNumber = $documentedMinimumBuildNumber
        documentedMinimumUbr = $documentedMinimumUbr
        observedBuildNumber = $buildNumber
        observedUbr = $ubr
        recomputedBuildEligible = $recomputedBuildEligible
        buildEligible = $odrBuildEligible
        executablePresent = $odrPresent
        baseEligible = $odrBaseEligible
        prerequisiteEligible = $odrPrerequisiteEligible
        prerequisiteStatus = $odrPrerequisiteStatus
        prerequisiteObservationAccepted = $odrPrerequisiteObservationAccepted
        productionPrerequisiteObservationAccepted = $productionOdrPrerequisiteObservationAccepted
    }
    executable = [ordered]@{
        deploymentPath = $deploymentOdrPath
        resolvedPath = $resolvedOdrPath
        sha256 = $odrSha256
        fileVersion = $fileVersion
        productVersion = $productVersion
    }
    authenticode = [ordered]@{
        status = $signatureStatus
        signerSubject = $signerSubject
        signerIssuer = $signerIssuer
        signerThumbprint = $signerThumbprint
    }
    versionProbe = [ordered]@{
        arguments = @('--version')
        exitCode = [int]$versionProbe.exitCode
        output = $versionText
        sideEffectClass = 'read-only'
    }
    prereleaseCommandSurface = [ordered]@{
        publicCliReferenceListsProvisionAgentUser = $false
        officialWindowsSampleUsesProvisionAgentUser = $true
        provisioningCommandEvidence = 'official-sample-only-not-public-cli-reference'
        requiresFreshExecutionAcknowledgement = $true
    }
    productionPlatformCheckSkipped = [bool]$SkipPlatformCheck
    productionIdentityVerified = $productionIdentityVerified
    runtimeFingerprintAccepted = $true
    acceptanceBoundary = [ordered]@{
        deploymentProfileAccepted = $true
        odrPrerequisiteAccepted = $true
        productionOdrPrerequisiteObservationAccepted = $productionOdrPrerequisiteObservationAccepted
        odrRuntimeIdentityAccepted = $true
        odrInventoryAccepted = $false
        activationPlanAccepted = $false
        agentUserProvisioned = $false
        proxySpawnAccepted = $false
        containmentRuntimeAccepted = $false
        protocolRuntimeAccepted = $false
        semanticToolAccepted = $false
        osStateReadbackAccepted = $false
    }
}

$receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReceiptPath -Encoding UTF8
$receipt
