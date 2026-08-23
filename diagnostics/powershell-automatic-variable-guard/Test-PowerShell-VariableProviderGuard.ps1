Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lintScript = Join-Path $PSScriptRoot 'Test-Scripts.ps1'
if (-not (Test-Path -LiteralPath $lintScript -PathType Leaf)) {
    throw "Missing Test-Scripts.ps1 at $lintScript"
}

$currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$shellPath = $currentProcess.MainModule.FileName
if ([string]::IsNullOrWhiteSpace($shellPath) -or -not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
    throw 'Could not resolve the current PowerShell executable for isolated provider fixtures.'
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("braintrust-provider-guard-{0}" -f [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tempRoot -Force)

function Invoke-BraintrustProviderLintFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][int]$ExpectedExitCode,
        [string]$ExpectedOutputFragment
    )

    $caseRoot = Join-Path $tempRoot $Name
    [void](New-Item -ItemType Directory -Path $caseRoot -Force)
    $fixturePath = Join-Path $caseRoot 'fixture.ps1'
    Set-Content -LiteralPath $fixturePath -Value $Content -Encoding UTF8

    $captured = (& $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $lintScript -Root $caseRoot 2>&1 | Out-String)
    $observedExitCode = $LASTEXITCODE
    if ($observedExitCode -ne $ExpectedExitCode) {
        throw "Fixture '$Name' expected exit $ExpectedExitCode but observed $observedExitCode. Output: $captured"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedOutputFragment) -and -not $captured.Contains($ExpectedOutputFragment)) {
        throw "Fixture '$Name' did not emit expected literal fragment '$ExpectedOutputFragment'. Output: $captured"
    }
}

# Native behavior probes on ordinary, isolated variables. These prove the provider
# semantics that the static guard relies on without mutating PowerShell-owned names.
$ordinaryProbe = 'BraintrustProviderOrdinaryProbe'
$wildcardProbeA = 'BraintrustProviderWildcardA'
$wildcardProbeB = 'BraintrustProviderWildcardB'
try {
    Set-Item -LiteralPath ("Variable:{0}" -f $ordinaryProbe) -Value 'set-value'
    if ((Get-Variable -Name $ordinaryProbe -ValueOnly) -ne 'set-value') {
        throw 'Set-Item Variable: ordinary probe did not update the target variable.'
    }

    Clear-Item -LiteralPath ("Variable:{0}" -f $ordinaryProbe)
    $cleared = Get-Variable -Name $ordinaryProbe -ErrorAction Stop
    if ($null -ne $cleared.Value) {
        throw 'Clear-Item Variable: ordinary probe did not clear the target variable.'
    }

    Set-Item -LiteralPath ("Variable:{0}" -f $ordinaryProbe) -Value 'remove-me'
    Remove-Item -LiteralPath ("Variable:{0}" -f $ordinaryProbe)
    if ($null -ne (Get-Variable -Name $ordinaryProbe -ErrorAction SilentlyContinue)) {
        throw 'Remove-Item Variable: ordinary probe did not remove the target variable.'
    }

    Set-Variable -Name $wildcardProbeA -Value 'before-A'
    Set-Variable -Name $wildcardProbeB -Value 'before-B'
    Set-Item -Path 'Variable:BraintrustProviderWildcard*' -Value 'wildcard-updated'
    if ((Get-Variable -Name $wildcardProbeA -ValueOnly) -ne 'wildcard-updated' -or
        (Get-Variable -Name $wildcardProbeB -ValueOnly) -ne 'wildcard-updated') {
        throw 'Set-Item -Path Variable: wildcard probe did not update both matching variables.'
    }
}
finally {
    Remove-Variable -Name $ordinaryProbe, $wildcardProbeA, $wildcardProbeB -Force -ErrorAction SilentlyContinue
}

try {
    Invoke-BraintrustProviderLintFixture -Name 'ordinary-variable-provider' -ExpectedExitCode 0 -ExpectedOutputFragment 'automatic-variable collision guard' -Content @'
Set-Item -LiteralPath 'Variable:ordinaryProviderTarget' -Value 1
'@

    Invoke-BraintrustProviderLintFixture -Name 'filesystem-path-is-not-variable-provider' -ExpectedExitCode 0 -ExpectedOutputFragment 'automatic-variable collision guard' -Content @'
Set-Item -LiteralPath '.\ordinary.txt' -Value 'x'
'@

    Invoke-BraintrustProviderLintFixture -Name 'literal-wildcard-remains-literal' -ExpectedExitCode 0 -ExpectedOutputFragment 'automatic-variable collision guard' -Content @'
Set-Item -LiteralPath 'Variable:P*' -Value 1
'@

    Invoke-BraintrustProviderLintFixture -Name 'set-item-literal-pid' -ExpectedExitCode 1 -ExpectedOutputFragment "set-item-variable-provider variable 'Variable:PID'" -Content @'
Set-Item -LiteralPath 'Variable:PID' -Value 1 -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'set-item-path-wildcard' -ExpectedExitCode 1 -ExpectedOutputFragment "set-item-variable-provider variable 'Variable:P*'" -Content @'
Set-Item -Path 'Variable:P*' -Value 1 -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'set-item-global-pid' -ExpectedExitCode 1 -ExpectedOutputFragment "set-item-variable-provider variable 'Variable:global:PID'" -Content @'
Set-Item -LiteralPath 'Variable:global:PID' -Value 1 -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'set-item-backslash-pid' -ExpectedExitCode 1 -ExpectedOutputFragment "set-item-variable-provider variable 'Variable:\PID'" -Content @'
Set-Item -LiteralPath 'Variable:\PID' -Value 1 -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'set-item-alias' -ExpectedExitCode 1 -ExpectedOutputFragment "set-item-variable-provider variable 'Variable:PID'" -Content @'
si -LiteralPath 'Variable:PID' -Value 1 -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'clear-item-wildcard' -ExpectedExitCode 1 -ExpectedOutputFragment "clear-item-variable-provider variable 'Variable:P*'" -Content @'
Clear-Item -Path 'Variable:P*' -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'clear-item-alias' -ExpectedExitCode 1 -ExpectedOutputFragment "clear-item-variable-provider variable 'Variable:PID'" -Content @'
cli -LiteralPath 'Variable:PID' -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'remove-item-pid' -ExpectedExitCode 1 -ExpectedOutputFragment "remove-item-variable-provider variable 'Variable:PID'" -Content @'
Remove-Item -LiteralPath 'Variable:PID' -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'remove-item-alias' -ExpectedExitCode 1 -ExpectedOutputFragment "remove-item-variable-provider variable 'Variable:PID'" -Content @'
ri -LiteralPath 'Variable:PID' -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'module-qualified-set-item' -ExpectedExitCode 1 -ExpectedOutputFragment "set-item-variable-provider variable 'Variable:Error'" -Content @'
Microsoft.PowerShell.Management\Set-Item -LiteralPath 'Variable:Error' -Value @() -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'adjacent-static-provider-path' -ExpectedExitCode 1 -ExpectedOutputFragment "set-item-variable-provider-adjacent-constant variable 'Variable:PID'" -Content @'
$providerPath = 'Variable:PID'
Set-Item -LiteralPath $providerPath -Value 1 -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'shadowed-si-function' -ExpectedExitCode 0 -ExpectedOutputFragment 'automatic-variable collision guard' -Content @'
function si { param($LiteralPath, $Value) Write-Output $LiteralPath }
si -LiteralPath 'Variable:PID' -Value 1
'@

    Invoke-BraintrustProviderLintFixture -Name 'current-location-ordinary-variable' -ExpectedExitCode 0 -ExpectedOutputFragment 'automatic-variable collision guard' -Content @'
Set-Location Variable:
Set-Item -LiteralPath ordinaryProviderTarget -Value 1
'@

    Invoke-BraintrustProviderLintFixture -Name 'current-location-set-item-pid' -ExpectedExitCode 1 -ExpectedOutputFragment "set-item-variable-provider-current-location variable 'PID'" -Content @'
Set-Location Variable:
Set-Item -LiteralPath PID -Value 1 -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'current-location-clear-item-pid' -ExpectedExitCode 1 -ExpectedOutputFragment "clear-item-variable-provider-current-location variable 'PID'" -Content @'
Set-Location -Path 'Variable:'; Clear-Item -LiteralPath PID -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'current-location-remove-item-pid' -ExpectedExitCode 1 -ExpectedOutputFragment "remove-item-variable-provider-current-location variable 'PID'" -Content @'
Microsoft.PowerShell.Management\Set-Location -LiteralPath 'Variable:'
Remove-Item -LiteralPath PID -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'current-location-wildcard-path' -ExpectedExitCode 1 -ExpectedOutputFragment "set-item-variable-provider-current-location variable 'P*'" -Content @'
Set-Location Variable:
Set-Item -Path 'P*' -Value 1 -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'current-location-literal-wildcard' -ExpectedExitCode 0 -ExpectedOutputFragment 'automatic-variable collision guard' -Content @'
Set-Location Variable:
Set-Item -LiteralPath 'P*' -Value 1 -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'non-variable-location-does-not-trigger' -ExpectedExitCode 0 -ExpectedOutputFragment 'automatic-variable collision guard' -Content @'
Set-Location .
Set-Item -LiteralPath PID -Value 1 -Force
'@

    Invoke-BraintrustProviderLintFixture -Name 'intervening-statement-declines-location-inference' -ExpectedExitCode 0 -ExpectedOutputFragment 'automatic-variable collision guard' -Content @'
Set-Location Variable:
Write-Output ok
Set-Item -LiteralPath PID -Value 1 -Force
'@
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'PowerShell Variable: provider guard regression PASS.' -ForegroundColor Green
