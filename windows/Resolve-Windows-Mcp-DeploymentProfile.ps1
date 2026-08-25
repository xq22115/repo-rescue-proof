param(
    [Parameter(Mandatory = $true)]
    [string]$ReceiptPath,

    [ValidateSet('auto', 'odr-msix-contained', 'mcpb-preview', 'direct-stdio-verified')]
    [string]$RequestedProfile = 'auto',

    [switch]$AllowPreviewOdr,
    [switch]$AllowReducedProtectionMcpb,
    [switch]$SkipPlatformCheck,

    [string]$OverrideBuildNumber,
    [Nullable[int]]$OverrideUbr,
    [Nullable[bool]]$OverrideOdrPresent,
    [Nullable[bool]]$OverrideDeveloperModeEnabled,
    [Nullable[bool]]$OverrideDotnetPresent,
    [Nullable[bool]]$OverrideMcpbCliPresent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Test-OverrideSupplied {
    return (
        -not [string]::IsNullOrWhiteSpace($OverrideBuildNumber) -or
        $null -ne $OverrideUbr -or
        $null -ne $OverrideOdrPresent -or
        $null -ne $OverrideDeveloperModeEnabled -or
        $null -ne $OverrideDotnetPresent -or
        $null -ne $OverrideMcpbCliPresent
    )
}

function Test-BuildAtLeast([int]$Build, [int]$Ubr, [int]$MinimumBuild, [int]$MinimumUbr) {
    if ($Build -gt $MinimumBuild) { return $true }
    if ($Build -lt $MinimumBuild) { return $false }
    return ($Ubr -ge $MinimumUbr)
}

function Get-CommandPresent([string[]]$Names) {
    foreach ($name in $Names) {
        if ($null -ne (Get-Command $name -ErrorAction SilentlyContinue)) { return $true }
    }
    return $false
}

$minimumOdrBuild = 26220
$minimumOdrUbr = 7262
$overrideSupplied = Test-OverrideSupplied

if ($overrideSupplied -and -not $SkipPlatformCheck) {
    throw 'Synthetic deployment-profile overrides are test-only and require -SkipPlatformCheck.'
}

if (-not $SkipPlatformCheck) {
    Assert-True ($env:OS -eq 'Windows_NT') 'Resolve-Windows-Mcp-DeploymentProfile.ps1 only supports Windows in production mode.'
}

$buildNumber = $null
$ubr = $null
$productName = $null
$displayVersion = $null
$editionId = $null
$odrPresent = $false
$odrPath = $null
$developerModeEnabled = $false
$dotnetPresent = $false
$mcpbCliPresent = $false

if ($SkipPlatformCheck) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($OverrideBuildNumber)) 'Test mode requires -OverrideBuildNumber.'
    Assert-True ($null -ne $OverrideUbr) 'Test mode requires -OverrideUbr.'
    Assert-True ($null -ne $OverrideOdrPresent) 'Test mode requires -OverrideOdrPresent.'
    Assert-True ($null -ne $OverrideDeveloperModeEnabled) 'Test mode requires -OverrideDeveloperModeEnabled.'
    Assert-True ($null -ne $OverrideDotnetPresent) 'Test mode requires -OverrideDotnetPresent.'
    Assert-True ($null -ne $OverrideMcpbCliPresent) 'Test mode requires -OverrideMcpbCliPresent.'

    # Windows PowerShell 5.1 boxes Nullable[T] parameters as their underlying scalar type.
    # Cast the already-null-checked values directly instead of dereferencing .Value.
    $buildNumber = [int]$OverrideBuildNumber
    $ubr = [int]$OverrideUbr
    $odrPresent = [bool]$OverrideOdrPresent
    $developerModeEnabled = [bool]$OverrideDeveloperModeEnabled
    $dotnetPresent = [bool]$OverrideDotnetPresent
    $mcpbCliPresent = [bool]$OverrideMcpbCliPresent
    $productName = 'synthetic-windows'
    $displayVersion = 'synthetic'
    $editionId = 'synthetic'
    if ($odrPresent) { $odrPath = 'C:\Windows\System32\odr.exe' }
} else {
    $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $buildNumber = [int]$currentVersion.CurrentBuildNumber
    $ubr = [int]$currentVersion.UBR
    $productName = [string]$currentVersion.ProductName
    $displayVersionProperty = $currentVersion.PSObject.Properties['DisplayVersion']
    if ($null -ne $displayVersionProperty) { $displayVersion = [string]$displayVersionProperty.Value }
    $editionProperty = $currentVersion.PSObject.Properties['EditionID']
    if ($null -ne $editionProperty) { $editionId = [string]$editionProperty.Value }

    $odrCommand = Get-Command 'odr.exe' -ErrorAction SilentlyContinue
    if ($null -ne $odrCommand) {
        $odrPresent = $true
        $odrPath = $odrCommand.Source
    }

    $developerModePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    if (Test-Path -LiteralPath $developerModePath) {
        $developerMode = Get-ItemProperty -LiteralPath $developerModePath -ErrorAction SilentlyContinue
        if ($null -ne $developerMode) {
            $developerModeProperty = $developerMode.PSObject.Properties['AllowDevelopmentWithoutDevLicense']
            if ($null -ne $developerModeProperty) {
                $developerModeEnabled = ([int]$developerModeProperty.Value -eq 1)
            }
        }
    }

    $dotnetPresent = Get-CommandPresent @('dotnet.exe', 'dotnet')
    $mcpbCliPresent = Get-CommandPresent @('mcpb.exe', 'mcpb')
}

$odrBuildEligible = Test-BuildAtLeast -Build $buildNumber -Ubr $ubr -MinimumBuild $minimumOdrBuild -MinimumUbr $minimumOdrUbr
$odrBaseEligible = ($odrBuildEligible -and $odrPresent)
$containedMsixEligible = $odrBaseEligible
$mcpbToolingEligible = ($odrBaseEligible -and $developerModeEnabled -and $dotnetPresent -and $mcpbCliPresent)

$odrPrerequisiteStatus = $null
if (-not $odrBuildEligible) {
    $odrPrerequisiteStatus = 'build-ineligible'
} elseif (-not $odrPresent) {
    $odrPrerequisiteStatus = 'build-eligible-odr-missing'
} else {
    $odrPrerequisiteStatus = 'build-eligible-odr-present'
}

$selectedProfile = $null
$selectionAccepted = $false
$selectionReason = $null
$containmentExpected = $false
$reducedProtectionRequired = $false
$previewFeatureRequired = $false

switch ($RequestedProfile) {
    'auto' {
        if ($AllowPreviewOdr -and $containedMsixEligible) {
            $selectedProfile = 'odr-msix-contained'
            $selectionAccepted = $true
            $selectionReason = 'Preview ODR was explicitly allowed and the machine meets the documented ODR build/tooling preflight.'
            $containmentExpected = $true
            $previewFeatureRequired = $true
        } else {
            $selectedProfile = 'direct-stdio-verified'
            $selectionAccepted = $true
            if (-not $AllowPreviewOdr) {
                $selectionReason = 'Preview ODR was not explicitly allowed; retain the verified direct-stdio lane instead of silently opting into a prerelease Windows agent-registry surface.'
            } elseif (-not $odrBuildEligible) {
                $selectionReason = 'The OS build is below the documented ODR prerequisite; retain the verified direct-stdio lane.'
            } elseif (-not $odrPresent) {
                $selectionReason = 'odr.exe was not found; retain the verified direct-stdio lane.'
            } else {
                $selectionReason = 'ODR preflight did not pass; retain the verified direct-stdio lane.'
            }
        }
    }
    'odr-msix-contained' {
        $previewFeatureRequired = $true
        $containmentExpected = $true
        if (-not $AllowPreviewOdr) {
            $selectionReason = 'odr-msix-contained is a prerelease Windows MCP surface and requires explicit -AllowPreviewOdr.'
        } elseif (-not $odrBuildEligible) {
            $selectionReason = "Windows build ${buildNumber}.${ubr} is below the documented minimum ${minimumOdrBuild}.${minimumOdrUbr}."
        } elseif (-not $odrPresent) {
            $selectionReason = 'odr.exe was not found on PATH.'
        } else {
            $selectedProfile = 'odr-msix-contained'
            $selectionAccepted = $true
            $selectionReason = 'Machine preflight supports the packaged ODR/MSIX containment lane. Server-specific package/manifest/capability checks remain separate acceptance gates.'
        }
    }
    'mcpb-preview' {
        $previewFeatureRequired = $true
        $reducedProtectionRequired = $true
        if (-not $AllowPreviewOdr) {
            $selectionReason = 'mcpb-preview depends on the prerelease Windows MCP registry and requires explicit -AllowPreviewOdr.'
        } elseif (-not $AllowReducedProtectionMcpb) {
            $selectionReason = 'MCP bundles cannot currently use Windows MCP containment; explicit -AllowReducedProtectionMcpb is required.'
        } elseif (-not $odrBuildEligible) {
            $selectionReason = "Windows build ${buildNumber}.${ubr} is below the documented minimum ${minimumOdrBuild}.${minimumOdrUbr}."
        } elseif (-not $odrPresent) {
            $selectionReason = 'odr.exe was not found on PATH.'
        } elseif (-not $developerModeEnabled) {
            $selectionReason = 'Developer Mode is not enabled, which the current MCP bundle tooling path documents as a prerequisite.'
        } elseif (-not $dotnetPresent) {
            $selectionReason = '.NET SDK/CLI was not found.'
        } elseif (-not $mcpbCliPresent) {
            $selectionReason = 'mcpb CLI was not found.'
        } else {
            $selectedProfile = 'mcpb-preview'
            $selectionAccepted = $true
            $selectionReason = 'MCP bundle preview prerequisites passed and reduced protection was explicitly acknowledged.'
        }
    }
    'direct-stdio-verified' {
        $selectedProfile = 'direct-stdio-verified'
        $selectionAccepted = $true
        $selectionReason = 'Direct stdio remains the explicit compatibility lane; executable identity, lifecycle, protocol, tool semantics, and OS read-back must still pass independently.'
    }
}

$receiptDirectory = Split-Path -Parent $ReceiptPath
if ($receiptDirectory) { New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null }

$receipt = [ordered]@{
    schemaVersion = 2
    component = 'windows-mcp-deployment-profile'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    requestedProfile = $RequestedProfile
    selectedProfile = $selectedProfile
    selectionAccepted = $selectionAccepted
    selectionReason = $selectionReason
    previewFeatureRequired = $previewFeatureRequired
    previewOdrExplicitlyAllowed = [bool]$AllowPreviewOdr
    reducedProtectionRequired = $reducedProtectionRequired
    reducedProtectionExplicitlyAllowed = [bool]$AllowReducedProtectionMcpb
    containmentExpected = $containmentExpected
    productionPlatformCheckSkipped = [bool]$SkipPlatformCheck
    preflightSideEffects = [ordered]@{
        mode = 'read-only'
        modifiesDeveloperMode = $false
        modifiesReducedProtections = $false
        installsDotnet = $false
        installsMcpbCli = $false
        registersMcpServer = $false
    }
    windows = [ordered]@{
        productName = $productName
        displayVersion = $displayVersion
        editionId = $editionId
        buildNumber = $buildNumber
        ubr = $ubr
    }
    odr = [ordered]@{
        documentedMinimumBuild = "${minimumOdrBuild}.${minimumOdrUbr}"
        documentedMinimumBuildNumber = $minimumOdrBuild
        documentedMinimumUbr = $minimumOdrUbr
        buildEligible = $odrBuildEligible
        executablePresent = $odrPresent
        executablePath = $odrPath
        baseEligible = $odrBaseEligible
        prerequisiteEligible = $odrBaseEligible
        prerequisiteStatus = $odrPrerequisiteStatus
        containedMsixEligible = $containedMsixEligible
    }
    mcpBundle = [ordered]@{
        developerModeEnabled = $developerModeEnabled
        dotnetPresent = $dotnetPresent
        mcpbCliPresent = $mcpbCliPresent
        toolingEligible = $mcpbToolingEligible
        containmentAvailable = $false
    }
    acceptanceBoundary = [ordered]@{
        deploymentProfileAccepted = $selectionAccepted
        odrPrerequisiteObservationAccepted = $true
        productionOdrPrerequisiteObservationAccepted = (-not [bool]$SkipPlatformCheck)
        odrRuntimeAccepted = $false
        packageIdentityAccepted = $false
        executableIdentityAccepted = $false
        lifecycleRuntimeAccepted = $false
        protocolRuntimeAccepted = $false
        semanticToolAccepted = $false
        osStateReadbackAccepted = $false
    }
}

$receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReceiptPath -Encoding UTF8

if (-not $selectionAccepted) {
    throw "Windows MCP deployment profile rejected: $selectionReason"
}

$receipt
