param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-ProfileCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Arguments,
        [bool]$ExpectSuccess = $true
    )

    $receipt = Join-Path $env:TEMP ("braintrust-mcp-profile-{0}-{1}.json" -f $Name, [Guid]::NewGuid().ToString('N'))
    $Arguments['ReceiptPath'] = $receipt
    $Arguments['SkipPlatformCheck'] = $true

    $threw = $false
    $errorMessage = $null
    try {
        & (Join-Path $PSScriptRoot 'Resolve-Windows-Mcp-DeploymentProfile.ps1') @Arguments | Out-Null
    } catch {
        $threw = $true
        $errorMessage = $_.Exception.Message
    }

    if ($ExpectSuccess) {
        Assert-True (-not $threw) "Case '$Name' unexpectedly failed: $errorMessage"
    } else {
        Assert-True $threw "Case '$Name' unexpectedly succeeded."
    }

    Assert-True (Test-Path -LiteralPath $receipt -PathType Leaf) "Case '$Name' did not emit a receipt."
    $parsed = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $receipt -Force
    return $parsed
}

$base = @{
    OverrideBuildNumber = '26220'
    OverrideUbr = 7262
    OverrideOdrPresent = $true
    OverrideDeveloperModeEnabled = $false
    OverrideDotnetPresent = $false
    OverrideMcpbCliPresent = $false
}

$containedArgs = $base.Clone()
$containedArgs['RequestedProfile'] = 'auto'
$containedArgs['AllowPreviewOdr'] = $true
$contained = Invoke-ProfileCase -Name 'contained-auto' -Arguments $containedArgs
Assert-True ($contained.schemaVersion -eq 2) 'Contained auto case emitted the wrong schema version.'
Assert-True ($contained.selectionAccepted -eq $true) 'Contained auto case was not accepted.'
Assert-True ($contained.selectedProfile -eq 'odr-msix-contained') 'Contained auto case did not choose ODR/MSIX containment.'
Assert-True ($contained.containmentExpected -eq $true) 'Contained auto case did not record expected containment.'
Assert-True ($contained.odr.documentedMinimumBuildNumber -eq 26220) 'Contained auto case emitted the wrong ODR minimum build number.'
Assert-True ($contained.odr.documentedMinimumUbr -eq 7262) 'Contained auto case emitted the wrong ODR minimum UBR.'
Assert-True ($contained.odr.prerequisiteStatus -eq 'build-eligible-odr-present') 'Contained auto case emitted the wrong ODR prerequisite status.'
Assert-True ($contained.odr.prerequisiteEligible -eq $true) 'Contained auto case did not record ODR prerequisite eligibility.'
Assert-True ($contained.preflightSideEffects.mode -eq 'read-only') 'Deployment preflight must be read-only.'
Assert-True ($contained.preflightSideEffects.modifiesReducedProtections -eq $false) 'Deployment preflight must not enable reduced protections.'
Assert-True ($contained.preflightSideEffects.modifiesDeveloperMode -eq $false) 'Deployment preflight must not enable Developer Mode.'
Assert-True ($contained.acceptanceBoundary.odrPrerequisiteObservationAccepted -eq $true) 'Deployment receipt did not preserve prerequisite observation acceptance.'
Assert-True ($contained.acceptanceBoundary.productionOdrPrerequisiteObservationAccepted -eq $false) 'Synthetic prerequisite observation was incorrectly promoted to production acceptance.'
Assert-True ($contained.acceptanceBoundary.odrRuntimeAccepted -eq $false) 'Deployment profile selection must not imply ODR runtime acceptance.'
Assert-True ($contained.acceptanceBoundary.protocolRuntimeAccepted -eq $false) 'Deployment profile selection must not imply protocol acceptance.'

$stableArgs = $base.Clone()
$stableArgs['RequestedProfile'] = 'auto'
$stableDefault = Invoke-ProfileCase -Name 'stable-default' -Arguments $stableArgs
Assert-True ($stableDefault.selectionAccepted -eq $true) 'Stable-default case was not accepted.'
Assert-True ($stableDefault.selectedProfile -eq 'direct-stdio-verified') 'Auto mode silently opted into prerelease ODR without explicit consent.'
Assert-True ($stableDefault.previewOdrExplicitlyAllowed -eq $false) 'Stable-default case misreported preview consent.'
Assert-True ($stableDefault.odr.prerequisiteStatus -eq 'build-eligible-odr-present') 'Stable-default case lost the independent ODR prerequisite observation.'
Assert-True ($stableDefault.acceptanceBoundary.odrRuntimeAccepted -eq $false) 'Stable-default case incorrectly promoted an eligible ODR prerequisite to ODR runtime acceptance.'

$belowMinimum = $base.Clone()
$belowMinimum['OverrideBuildNumber'] = '26220'
$belowMinimum['OverrideUbr'] = 7000
$belowMinimum['RequestedProfile'] = 'odr-msix-contained'
$belowMinimum['AllowPreviewOdr'] = $true
$rejectedOdr = Invoke-ProfileCase -Name 'below-minimum' -Arguments $belowMinimum -ExpectSuccess $false
Assert-True ($rejectedOdr.selectionAccepted -eq $false) 'Below-minimum ODR case did not fail closed.'
Assert-True ($rejectedOdr.odr.buildEligible -eq $false) 'Below-minimum ODR case misreported build eligibility.'
Assert-True ($rejectedOdr.odr.prerequisiteEligible -eq $false) 'Below-minimum ODR case misreported prerequisite eligibility.'
Assert-True ($rejectedOdr.odr.prerequisiteStatus -eq 'build-ineligible') 'Below-minimum ODR case emitted the wrong prerequisite status.'

$missingOdrArgs = $base.Clone()
$missingOdrArgs['OverrideOdrPresent'] = $false
$missingOdrArgs['RequestedProfile'] = 'auto'
$missingOdrArgs['AllowPreviewOdr'] = $true
$missingOdr = Invoke-ProfileCase -Name 'eligible-build-missing-odr' -Arguments $missingOdrArgs
Assert-True ($missingOdr.selectionAccepted -eq $true) 'Eligible-build/missing-ODR auto case should retain a compatibility lane.'
Assert-True ($missingOdr.selectedProfile -eq 'direct-stdio-verified') 'Eligible-build/missing-ODR auto case did not retain direct stdio.'
Assert-True ($missingOdr.odr.buildEligible -eq $true) 'Eligible-build/missing-ODR case lost build eligibility.'
Assert-True ($missingOdr.odr.executablePresent -eq $false) 'Eligible-build/missing-ODR case misreported odr.exe presence.'
Assert-True ($missingOdr.odr.prerequisiteEligible -eq $false) 'Eligible-build/missing-ODR case incorrectly accepted ODR prerequisites.'
Assert-True ($missingOdr.odr.prerequisiteStatus -eq 'build-eligible-odr-missing') 'Eligible-build/missing-ODR case emitted the wrong prerequisite status.'
Assert-True ($missingOdr.acceptanceBoundary.odrRuntimeAccepted -eq $false) 'Eligible-build/missing-ODR case incorrectly promoted ODR runtime acceptance.'

$missingOdrExplicitArgs = $base.Clone()
$missingOdrExplicitArgs['OverrideOdrPresent'] = $false
$missingOdrExplicitArgs['RequestedProfile'] = 'odr-msix-contained'
$missingOdrExplicitArgs['AllowPreviewOdr'] = $true
$missingOdrExplicit = Invoke-ProfileCase -Name 'explicit-odr-missing-executable' -Arguments $missingOdrExplicitArgs -ExpectSuccess $false
Assert-True ($missingOdrExplicit.odr.prerequisiteStatus -eq 'build-eligible-odr-missing') 'Explicit ODR/missing-executable case emitted the wrong prerequisite status.'
Assert-True ($missingOdrExplicit.acceptanceBoundary.odrRuntimeAccepted -eq $false) 'Explicit ODR/missing-executable case incorrectly promoted ODR runtime acceptance.'

$mcpbBase = @{
    OverrideBuildNumber = '26220'
    OverrideUbr = 7262
    OverrideOdrPresent = $true
    OverrideDeveloperModeEnabled = $true
    OverrideDotnetPresent = $true
    OverrideMcpbCliPresent = $true
    RequestedProfile = 'mcpb-preview'
    AllowPreviewOdr = $true
}

$mcpbRejected = Invoke-ProfileCase -Name 'mcpb-no-reduced-protection' -Arguments $mcpbBase.Clone() -ExpectSuccess $false
Assert-True ($mcpbRejected.selectionAccepted -eq $false) 'MCP bundle case without reduced-protection acknowledgement did not fail closed.'
Assert-True ($mcpbRejected.reducedProtectionRequired -eq $true) 'MCP bundle case did not record reduced-protection requirement.'
Assert-True ($mcpbRejected.mcpBundle.containmentAvailable -eq $false) 'MCP bundle case incorrectly claimed Windows containment.'

$mcpbAcceptedArgs = $mcpbBase.Clone()
$mcpbAcceptedArgs['AllowReducedProtectionMcpb'] = $true
$mcpbAccepted = Invoke-ProfileCase -Name 'mcpb-explicit' -Arguments $mcpbAcceptedArgs
Assert-True ($mcpbAccepted.selectionAccepted -eq $true) 'Explicit MCP bundle preview case was not accepted.'
Assert-True ($mcpbAccepted.selectedProfile -eq 'mcpb-preview') 'Explicit MCP bundle preview case selected the wrong profile.'
Assert-True ($mcpbAccepted.containmentExpected -eq $false) 'MCP bundle preview incorrectly claimed containment.'
Assert-True ($mcpbAccepted.reducedProtectionExplicitlyAllowed -eq $true) 'MCP bundle preview did not record explicit reduced-protection acknowledgement.'
Assert-True ($mcpbAccepted.preflightSideEffects.modifiesReducedProtections -eq $false) 'MCP bundle profile selection must not change the Windows reduced-protection setting.'
Assert-True ($mcpbAccepted.acceptanceBoundary.lifecycleRuntimeAccepted -eq $false) 'Deployment profile selection must not imply lifecycle acceptance.'

$overrideGuardArgs = $base.Clone()
$overrideGuardArgs['RequestedProfile'] = 'direct-stdio-verified'
$overrideReceipt = Join-Path $env:TEMP ("braintrust-mcp-profile-override-guard-{0}.json" -f [Guid]::NewGuid().ToString('N'))
$overrideGuardArgs['ReceiptPath'] = $overrideReceipt
$overrideGuardThrew = $false
try {
    & (Join-Path $PSScriptRoot 'Resolve-Windows-Mcp-DeploymentProfile.ps1') @overrideGuardArgs | Out-Null
} catch {
    $overrideGuardThrew = $true
}
Assert-True $overrideGuardThrew 'Synthetic overrides were accepted without -SkipPlatformCheck.'
if (Test-Path -LiteralPath $overrideReceipt) { Remove-Item -LiteralPath $overrideReceipt -Force }

Write-Host '[PASS] Windows MCP deployment profile contract with machine-readable ODR prerequisite status' -ForegroundColor Green
exit 0
