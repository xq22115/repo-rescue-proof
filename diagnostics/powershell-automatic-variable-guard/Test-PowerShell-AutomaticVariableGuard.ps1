Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lintScript = Join-Path $PSScriptRoot 'Test-Scripts.ps1'
if (-not (Test-Path -LiteralPath $lintScript -PathType Leaf)) {
    throw "Missing Test-Scripts.ps1 at $lintScript"
}

$currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$shellPath = $currentProcess.MainModule.FileName
if ([string]::IsNullOrWhiteSpace($shellPath) -or -not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
    throw 'Could not resolve the current PowerShell executable for isolated lint fixtures.'
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("braintrust-automatic-variable-guard-{0}" -f [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tempRoot -Force)

function Invoke-BraintrustLintFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedExitCode,

        [string]$ExpectedOutputPattern
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

    if (-not [string]::IsNullOrWhiteSpace($ExpectedOutputPattern) -and $captured -notmatch $ExpectedOutputPattern) {
        throw "Fixture '$Name' did not emit expected pattern '$ExpectedOutputPattern'. Output: $captured"
    }
}

# Native behavior probe: the static guard relies on PowerShell's documented
# unique-prefix binding semantics, so prove the current shell actually binds
# -N, -Na, and -Nam to Set-Variable -Name before accepting the regression.
$runtimePrefixProbeN = 'BraintrustPrefixProbeN'
$runtimePrefixProbeNa = 'BraintrustPrefixProbeNa'
$runtimePrefixProbeNam = 'BraintrustPrefixProbeNam'
try {
    Set-Variable -N $runtimePrefixProbeN -Value 'N-bound'
    Set-Variable -Na $runtimePrefixProbeNa -Value 'Na-bound'
    Set-Variable -Nam $runtimePrefixProbeNam -Value 'Nam-bound'

    if ((Get-Variable -Name $runtimePrefixProbeN -ValueOnly) -ne 'N-bound') {
        throw 'Set-Variable -N did not bind to -Name in the current PowerShell runtime.'
    }
    if ((Get-Variable -Name $runtimePrefixProbeNa -ValueOnly) -ne 'Na-bound') {
        throw 'Set-Variable -Na did not bind to -Name in the current PowerShell runtime.'
    }
    if ((Get-Variable -Name $runtimePrefixProbeNam -ValueOnly) -ne 'Nam-bound') {
        throw 'Set-Variable -Nam did not bind to -Name in the current PowerShell runtime.'
    }
}
finally {
    Remove-Variable -Name $runtimePrefixProbeN, $runtimePrefixProbeNa, $runtimePrefixProbeNam -Force -ErrorAction SilentlyContinue
}

try {
    Invoke-BraintrustLintFixture -Name 'safe-reads-and-ordinary-writes' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
$nativeWindowsObserved = $IsWindows
$processIdObserved = $PID
$hostNameObserved = $Host.Name
$ordinaryValue = 1
$leftValue, $rightValue = 1, 2
foreach ($item in 1..2) { $ordinaryValue += $item }
$ordinaryValue++
--$ordinaryValue
Set-Variable -Name ordinaryValue -Value 3
Set-Variable -N ordinaryValue -Value 4
$namePart = 'ordinary'
$name = ($namePart + 'Value')
Set-Variable -Name $name -Value 5
$targetName = 'PID'
$targetName = 'ordinaryValue'
Set-Variable -Name $targetName -Value 6
$obj = [pscustomobject]@{ Value = 1 }
$obj.Value++
$env:HOME = 'fixture-only'
'@

    Invoke-BraintrustLintFixture -Name 'shadowed-set-function-is-not-builtin-alias' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
function set {
    param($Name, $Value)
    Write-Output "$Name=$Value"
}
set PID 1
'@

    Invoke-BraintrustLintFixture -Name 'case-insensitive-iswindows-assignment' -ExpectedExitCode 1 -ExpectedOutputPattern "assignment variable 'isWindows'.*automatic variable" -Content @'
$isWindows = $true
'@

    Invoke-BraintrustLintFixture -Name 'scoped-pid-assignment' -ExpectedExitCode 1 -ExpectedOutputPattern "assignment variable 'script:PID'.*automatic variable" -Content @'
$script:PID = 42
'@

    Invoke-BraintrustLintFixture -Name 'automatic-variable-parameter' -ExpectedExitCode 1 -ExpectedOutputPattern "parameter variable 'Host'.*automatic variable" -Content @'
param([string]$Host)
Write-Output 'never executed by the lint gate'
'@

    Invoke-BraintrustLintFixture -Name 'foreach-error-variable' -ExpectedExitCode 1 -ExpectedOutputPattern "foreach-variable variable 'error'.*automatic variable" -Content @'
foreach ($error in 1..2) { Write-Output $error }
'@

    Invoke-BraintrustLintFixture -Name 'tuple-pid-assignment' -ExpectedExitCode 1 -ExpectedOutputPattern "assignment variable 'PID'.*automatic variable" -Content @'
$safeValue, $PID = 1, 2
'@

    Invoke-BraintrustLintFixture -Name 'prefix-automatic-variable-increment' -ExpectedExitCode 1 -ExpectedOutputPattern "unary-write variable 'pid'.*automatic variable" -Content @'
++$pid
'@

    Invoke-BraintrustLintFixture -Name 'postfix-scoped-automatic-variable-decrement' -ExpectedExitCode 1 -ExpectedOutputPattern "unary-write variable 'script:PID'.*automatic variable" -Content @'
$script:PID--
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-adjacent-literal-name' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable-adjacent-constant variable 'PID'.*automatic variable" -Content @'
$name = 'PID'
Set-Variable -Name $name -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-abbreviated-adjacent-literal-name' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable-adjacent-constant variable 'PID'.*automatic variable" -Content @'
$name = 'PID'
Set-Variable -N $name -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-alias-adjacent-literal-name' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable-adjacent-constant variable 'host'.*automatic variable" -Content @'
$name = 'host'
sv -Name $name -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-adjacent-ordinary-name' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
$name = 'ordinaryValue'
Set-Variable -Name $name -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-nonliteral-name-remains-unresolved' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
$prefix = 'P'
$name = ($prefix + 'ID')
Set-Variable -Name $name -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-explicit-name' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable variable 'PID'.*automatic variable" -Content @'
Set-Variable -Name PID -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-abbreviated-n-name' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable variable 'PID'.*automatic variable" -Content @'
Set-Variable -N PID -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-abbreviated-na-name' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable variable 'host'.*automatic variable" -Content @'
Set-Variable -Na host -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-alias-abbreviated-nam-name' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable variable 'Error'.*automatic variable" -Content @'
sv -Nam Error -Value @()
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-alias-explicit-name' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable variable 'host'.*automatic variable" -Content @'
sv -Name host -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-alias-positional-name' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable variable 'PID'.*automatic variable" -Content @'
set PID 1
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-module-qualified' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable variable 'Error'.*automatic variable" -Content @'
Microsoft.PowerShell.Utility\Set-Variable -Name Error -Value @()
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-module-qualified-abbreviated-name' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable variable 'Error'.*automatic variable" -Content @'
Microsoft.PowerShell.Utility\Set-Variable -Nam Error -Value @()
'@
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'PowerShell automatic-variable collision guard regression PASS.' -ForegroundColor Green
