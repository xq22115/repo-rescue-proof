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

# Native behavior probe: named parameters may precede mandatory position-0 Name.
$runtimeSetLeadingForceProbe = 'BraintrustSetLeadingForceProbe'
$runtimeSetLeadingErrorActionProbe = 'BraintrustSetLeadingErrorActionProbe'
try {
    Set-Variable -Force $runtimeSetLeadingForceProbe -Value 'set-force-leading'
    Set-Variable -ErrorAction Stop $runtimeSetLeadingErrorActionProbe -Value 'set-erroraction-leading'
    if ((Get-Variable -Name $runtimeSetLeadingForceProbe -ValueOnly) -ne 'set-force-leading') { throw 'Set-Variable positional Name after -Force failed.' }
    if ((Get-Variable -Name $runtimeSetLeadingErrorActionProbe -ValueOnly) -ne 'set-erroraction-leading') { throw 'Set-Variable positional Name after -ErrorAction failed.' }
}
finally {
    Remove-Variable -Name $runtimeSetLeadingForceProbe, $runtimeSetLeadingErrorActionProbe -Force -ErrorAction SilentlyContinue
}

# Native behavior probe: New-Variable shares the same unique -Name prefix surface,
# and -Force can replace an existing ReadOnly variable. Prove those semantics on an
# ordinary isolated variable before relying on the static New-Variable write guard.
$runtimeNewPrefixProbeN = 'BraintrustNewPrefixProbeN'
$runtimeNewPrefixProbeNa = 'BraintrustNewPrefixProbeNa'
$runtimeNewPrefixProbeNam = 'BraintrustNewPrefixProbeNam'
$runtimeNewAliasProbe = 'BraintrustNewAliasProbe'
$runtimeReadOnlyProbe = 'BraintrustNewForceReadOnlyProbe'
$runtimeNewLeadingForceProbe = 'BraintrustNewLeadingForceProbe'
$runtimeNewLeadingErrorActionProbe = 'BraintrustNewLeadingErrorActionProbe'
try {
    New-Variable -N $runtimeNewPrefixProbeN -Value 'N-created'
    New-Variable -Na $runtimeNewPrefixProbeNa -Value 'Na-created'
    New-Variable -Nam $runtimeNewPrefixProbeNam -Value 'Nam-created'
    nv -Nam $runtimeNewAliasProbe -Value 'nv-created'
    New-Variable -Name $runtimeReadOnlyProbe -Value 'original' -Option ReadOnly
    New-Variable -N $runtimeReadOnlyProbe -Value 'replaced' -Force
    New-Variable -Force $runtimeNewLeadingForceProbe -Value 'new-force-leading'
    New-Variable -ErrorAction Stop $runtimeNewLeadingErrorActionProbe -Value 'new-erroraction-leading'

    if ((Get-Variable -Name $runtimeNewPrefixProbeN -ValueOnly) -ne 'N-created') {
        throw 'New-Variable -N did not bind to -Name in the current PowerShell runtime.'
    }
    if ((Get-Variable -Name $runtimeNewPrefixProbeNa -ValueOnly) -ne 'Na-created') {
        throw 'New-Variable -Na did not bind to -Name in the current PowerShell runtime.'
    }
    if ((Get-Variable -Name $runtimeNewPrefixProbeNam -ValueOnly) -ne 'Nam-created') {
        throw 'New-Variable -Nam did not bind to -Name in the current PowerShell runtime.'
    }
    if ((Get-Variable -Name $runtimeNewAliasProbe -ValueOnly) -ne 'nv-created') {
        throw 'The built-in nv alias did not resolve to New-Variable in the current PowerShell runtime.'
    }
    if ((Get-Variable -Name $runtimeReadOnlyProbe -ValueOnly) -ne 'replaced') {
        throw 'New-Variable -Force did not replace the current ReadOnly probe variable.'
    }
    if ((Get-Variable -Name $runtimeNewLeadingForceProbe -ValueOnly) -ne 'new-force-leading') { throw 'New-Variable positional Name after -Force failed.' }
    if ((Get-Variable -Name $runtimeNewLeadingErrorActionProbe -ValueOnly) -ne 'new-erroraction-leading') { throw 'New-Variable positional Name after -ErrorAction failed.' }
}
finally {
    Remove-Variable -Name $runtimeNewPrefixProbeN, $runtimeNewPrefixProbeNa, $runtimeNewPrefixProbeNam, $runtimeNewAliasProbe, $runtimeReadOnlyProbe, $runtimeNewLeadingForceProbe, $runtimeNewLeadingErrorActionProbe -Force -ErrorAction SilentlyContinue
}

# Native behavior probe: Clear-Variable and Remove-Variable share the same
# mandatory position-0 Name and unique -Name prefix surface. Prove -N/-Na/-Nam
# binding on ordinary variables before relying on the static destructive-write guard.
$runtimeClearProbeN = 'BraintrustClearProbeN'
$runtimeClearProbeNa = 'BraintrustClearProbeNa'
$runtimeClearProbeNam = 'BraintrustClearProbeNam'
$runtimeRemoveProbeN = 'BraintrustRemoveProbeN'
$runtimeRemoveProbeNa = 'BraintrustRemoveProbeNa'
$runtimeRemoveProbeNam = 'BraintrustRemoveProbeNam'
try {
    Set-Variable -Name $runtimeClearProbeN -Value 'clear-N'
    Set-Variable -Name $runtimeClearProbeNa -Value 'clear-Na'
    Set-Variable -Name $runtimeClearProbeNam -Value 'clear-Nam'
    Clear-Variable -N $runtimeClearProbeN
    Clear-Variable -Na $runtimeClearProbeNa
    Clear-Variable -Nam $runtimeClearProbeNam
    foreach ($probeName in @($runtimeClearProbeN, $runtimeClearProbeNa, $runtimeClearProbeNam)) {
        $probe = Get-Variable -Name $probeName -ErrorAction Stop
        if ($null -ne $probe.Value) { throw "Clear-Variable unique -Name prefix did not clear $probeName." }
    }

    Set-Variable -Name $runtimeRemoveProbeN -Value 'remove-N'
    Set-Variable -Name $runtimeRemoveProbeNa -Value 'remove-Na'
    Set-Variable -Name $runtimeRemoveProbeNam -Value 'remove-Nam'
    Remove-Variable -N $runtimeRemoveProbeN
    Remove-Variable -Na $runtimeRemoveProbeNa
    Remove-Variable -Nam $runtimeRemoveProbeNam
    foreach ($probeName in @($runtimeRemoveProbeN, $runtimeRemoveProbeNa, $runtimeRemoveProbeNam)) {
        if ($null -ne (Get-Variable -Name $probeName -ErrorAction SilentlyContinue)) { throw "Remove-Variable unique -Name prefix did not remove $probeName." }
    }
}
finally {
    Remove-Variable -Name $runtimeClearProbeN, $runtimeClearProbeNa, $runtimeClearProbeNam, $runtimeRemoveProbeN, $runtimeRemoveProbeNa, $runtimeRemoveProbeNam -Force -ErrorAction SilentlyContinue
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
New-Variable -Name ordinaryCreatedValue -Value 7
nv -N ordinaryAliasCreatedValue -Value 8
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

    Invoke-BraintrustLintFixture -Name 'shadowed-nv-function-is-not-builtin-alias' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
function nv {
    param($Name, $Value)
    Write-Output "$Name=$Value"
}
nv PID 1
'@

    Invoke-BraintrustLintFixture -Name 'later-set-function-does-not-shadow-earlier-builtin-alias' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable variable 'PID'.*automatic variable" -Content @'
set PID 1
function set {
    param($Name, $Value)
    Write-Output "$Name=$Value"
}
'@

    Invoke-BraintrustLintFixture -Name 'later-nv-function-does-not-shadow-earlier-builtin-alias' -ExpectedExitCode 1 -ExpectedOutputPattern "new-variable variable 'PID'.*automatic variable" -Content @'
nv PID 1 -Force
function nv {
    param($Name, $Value)
    Write-Output "$Name=$Value"
}
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


    Invoke-BraintrustLintFixture -Name 'set-variable-leading-force-positional-name' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable variable 'PID'.*automatic variable" -Content @'
Set-Variable -Force PID -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'set-variable-leading-erroraction-positional-name' -ExpectedExitCode 1 -ExpectedOutputPattern "set-variable variable 'host'.*automatic variable" -Content @'
Set-Variable -ErrorAction Stop host -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'new-variable-adjacent-literal-name' -ExpectedExitCode 1 -ExpectedOutputPattern "new-variable-adjacent-constant variable 'PID'.*automatic variable" -Content @'
$name = 'PID'
New-Variable -N $name -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'new-variable-adjacent-ordinary-name' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
$name = 'ordinaryCreatedValue'
New-Variable -Name $name -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'new-variable-explicit-name' -ExpectedExitCode 1 -ExpectedOutputPattern "new-variable variable 'PID'.*automatic variable" -Content @'
New-Variable -Name PID -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'new-variable-leading-force-positional-name' -ExpectedExitCode 1 -ExpectedOutputPattern "new-variable variable 'PID'.*automatic variable" -Content @'
New-Variable -Force PID -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'new-variable-leading-erroraction-positional-name' -ExpectedExitCode 1 -ExpectedOutputPattern "new-variable variable 'host'.*automatic variable" -Content @'
New-Variable -ErrorAction Stop host -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'new-variable-abbreviated-n-name' -ExpectedExitCode 1 -ExpectedOutputPattern "new-variable variable 'host'.*automatic variable" -Content @'
New-Variable -N host -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'new-variable-alias-abbreviated-nam-name' -ExpectedExitCode 1 -ExpectedOutputPattern "new-variable variable 'Error'.*automatic variable" -Content @'
nv -Nam Error -Value @() -Force
'@

    Invoke-BraintrustLintFixture -Name 'new-variable-positional-name' -ExpectedExitCode 1 -ExpectedOutputPattern "new-variable variable 'PID'.*automatic variable" -Content @'
New-Variable PID 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'new-variable-module-qualified' -ExpectedExitCode 1 -ExpectedOutputPattern "new-variable variable 'Error'.*automatic variable" -Content @'
Microsoft.PowerShell.Utility\New-Variable -Name Error -Value @() -Force
'@

    Invoke-BraintrustLintFixture -Name 'clear-variable-ordinary-name' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
$ordinaryClearTarget = 1
Clear-Variable -Name ordinaryClearTarget
'@

    Invoke-BraintrustLintFixture -Name 'remove-variable-ordinary-name' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
$ordinaryRemoveTarget = 1
Remove-Variable -Name ordinaryRemoveTarget
'@

    Invoke-BraintrustLintFixture -Name 'clear-variable-explicit-automatic-name' -ExpectedExitCode 1 -ExpectedOutputPattern "clear-variable variable 'PID'.*automatic variable" -Content @'
Clear-Variable -Name PID -Force
'@

    Invoke-BraintrustLintFixture -Name 'clear-variable-alias-abbreviated-name' -ExpectedExitCode 1 -ExpectedOutputPattern "clear-variable variable 'Error'.*automatic variable" -Content @'
clv -Nam Error -Force
'@

    Invoke-BraintrustLintFixture -Name 'clear-variable-module-qualified' -ExpectedExitCode 1 -ExpectedOutputPattern "clear-variable variable 'host'.*automatic variable" -Content @'
Microsoft.PowerShell.Utility\Clear-Variable -N host -Force
'@

    Invoke-BraintrustLintFixture -Name 'clear-variable-adjacent-constant' -ExpectedExitCode 1 -ExpectedOutputPattern "clear-variable-adjacent-constant variable 'PID'.*automatic variable" -Content @'
$name = 'PID'
Clear-Variable -Name $name -Force
'@

    Invoke-BraintrustLintFixture -Name 'clear-variable-all-variables-pattern' -ExpectedExitCode 1 -ExpectedOutputPattern "clear-variable-all-variables-pattern variable '\*'.*automatic variable" -Content @'
Clear-Variable -Name '*' -Force
'@

    Invoke-BraintrustLintFixture -Name 'remove-variable-explicit-automatic-name' -ExpectedExitCode 1 -ExpectedOutputPattern "remove-variable variable 'PID'.*automatic variable" -Content @'
Remove-Variable -Name PID -Force
'@

    Invoke-BraintrustLintFixture -Name 'remove-variable-alias-abbreviated-name' -ExpectedExitCode 1 -ExpectedOutputPattern "remove-variable variable 'host'.*automatic variable" -Content @'
rv -Na host -Force
'@

    Invoke-BraintrustLintFixture -Name 'remove-variable-module-qualified' -ExpectedExitCode 1 -ExpectedOutputPattern "remove-variable variable 'Error'.*automatic variable" -Content @'
Microsoft.PowerShell.Utility\Remove-Variable -Nam Error -Force
'@

    Invoke-BraintrustLintFixture -Name 'remove-variable-adjacent-constant' -ExpectedExitCode 1 -ExpectedOutputPattern "remove-variable-adjacent-constant variable 'PID'.*automatic variable" -Content @'
$name = 'PID'
Remove-Variable -Name $name -Force
'@

    Invoke-BraintrustLintFixture -Name 'remove-variable-all-variables-pattern' -ExpectedExitCode 1 -ExpectedOutputPattern "remove-variable-all-variables-pattern variable '\*'.*automatic variable" -Content @'
Remove-Variable -Name '*' -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-set-item-ordinary-variable' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
Set-Item -LiteralPath 'Variable:ordinaryProviderTarget' -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'provider-set-item-filesystem-path-is-not-variable-provider' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
Set-Item -LiteralPath '.\\ordinary.txt' -Value 'x'
'@

    Invoke-BraintrustLintFixture -Name 'provider-literal-wildcard-is-not-treated-as-path-wildcard' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
Set-Item -LiteralPath 'Variable:P*' -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'provider-set-item-literal-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider variable 'Variable:PID'.*automatic variable" -Content @'
Set-Item -LiteralPath 'Variable:PID' -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-set-item-path-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider variable 'Variable:PID'.*automatic variable" -Content @'
Set-Item -Path 'Variable:PID' -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-set-item-positional-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider variable 'Variable:PID'.*automatic variable" -Content @'
Set-Item 'Variable:PID' -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-set-item-leading-force-positional-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider variable 'Variable:PID'.*automatic variable" -Content @'
Set-Item -Force 'Variable:PID' -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'provider-set-item-backslash-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider variable 'Variable:\\PID'.*automatic variable" -Content @'
Set-Item -LiteralPath 'Variable:\PID' -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-set-item-global-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider variable 'Variable:global:PID'.*automatic variable" -Content @'
Set-Item -LiteralPath 'Variable:global:PID' -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-set-item-wildcard-path' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider variable 'Variable:P\*'.*automatic variable" -Content @'
Set-Item -Path 'Variable:P*' -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-set-item-alias-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider variable 'Variable:PID'.*automatic variable" -Content @'
si -LiteralPath 'Variable:PID' -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-clear-item-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "clear-item-variable-provider variable 'Variable:PID'.*automatic variable" -Content @'
Clear-Item -LiteralPath 'Variable:PID' -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-clear-item-wildcard' -ExpectedExitCode 1 -ExpectedOutputPattern "clear-item-variable-provider variable 'Variable:P\*'.*automatic variable" -Content @'
Clear-Item -Path 'Variable:P*' -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-clear-item-alias-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "clear-item-variable-provider variable 'Variable:PID'.*automatic variable" -Content @'
cli -LiteralPath 'Variable:PID' -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-remove-item-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "remove-item-variable-provider variable 'Variable:PID'.*automatic variable" -Content @'
Remove-Item -LiteralPath 'Variable:PID' -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-remove-item-alias-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "remove-item-variable-provider variable 'Variable:PID'.*automatic variable" -Content @'
ri -LiteralPath 'Variable:PID' -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-module-qualified-set-item-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider variable 'Variable:Error'.*automatic variable" -Content @'
Microsoft.PowerShell.Management\Set-Item -LiteralPath 'Variable:Error' -Value @() -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-set-item-adjacent-constant' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider-adjacent-constant variable 'Variable:PID'.*automatic variable" -Content @'
$providerPath = 'Variable:PID'
Set-Item -LiteralPath $providerPath -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-shadowed-si-function-is-not-builtin-alias' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
function si { param($LiteralPath, $Value) Write-Output $LiteralPath }
si -LiteralPath 'Variable:PID' -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-ordinary-variable' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
Set-Location Variable:
Set-Item -LiteralPath ordinaryProviderTarget -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-push-location-ordinary-variable' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
Push-Location Variable:
Set-Item -LiteralPath ordinaryProviderTarget -Value 1
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-push-location-set-item-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider-current-location-ambiguous-command-identity variable 'PID'.*automatic variable" -Content @'
Push-Location Variable:
Set-Item -LiteralPath PID -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-push-location-explicit-path-clear-item-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "clear-item-variable-provider-current-location-ambiguous-command-identity variable 'PID'.*automatic variable" -Content @'
Push-Location -Path 'Variable:'
Clear-Item -LiteralPath PID -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-push-location-non-variable-location' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
Push-Location .
Set-Item -LiteralPath PID -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-set-item-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider-current-location-ambiguous-command-identity variable 'PID'.*automatic variable" -Content @'
Set-Location Variable:
Set-Item -LiteralPath PID -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-clear-item-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "clear-item-variable-provider-current-location-ambiguous-command-identity variable 'PID'.*automatic variable" -Content @'
Set-Location -Path 'Variable:'; Clear-Item -LiteralPath PID -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-remove-item-pid' -ExpectedExitCode 1 -ExpectedOutputPattern "remove-item-variable-provider-current-location variable 'PID'.*automatic variable" -Content @'
Microsoft.PowerShell.Management\Set-Location -LiteralPath 'Variable:'
Remove-Item -LiteralPath PID -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-wildcard' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider-current-location-ambiguous-command-identity variable 'P\*'.*automatic variable" -Content @'
Set-Location Variable:
Set-Item -Path 'P*' -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-literal-wildcard-remains-literal' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
Set-Location Variable:
Set-Item -LiteralPath 'P*' -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-non-variable-location' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
Set-Location .
Set-Item -LiteralPath PID -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-intervening-statement-declines-inference' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
Set-Location Variable:
Write-Output ok
Set-Item -LiteralPath PID -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-shadowed-set-location-does-not-infer-provider' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
function Set-Location { param([string]$Path) Write-Output "shadow:$Path" }
Set-Location Variable:
Set-Item -LiteralPath PID -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-shadowed-push-location-does-not-infer-provider' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
function Push-Location { param([string]$Path) Write-Output "shadow:$Path" }
Push-Location Variable:
Set-Item -LiteralPath PID -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-module-qualified-set-location-bypasses-shadow' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider-current-location variable 'PID'.*automatic variable" -Content @'
function Set-Location { param([string]$Path) Write-Output "shadow:$Path" }
Microsoft.PowerShell.Management\Set-Location -LiteralPath 'Variable:'
Set-Item -LiteralPath PID -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-module-qualified-push-location-bypasses-shadow' -ExpectedExitCode 1 -ExpectedOutputPattern "set-item-variable-provider-current-location variable 'PID'.*automatic variable" -Content @'
function Push-Location { param([string]$Path) Write-Output "shadow:$Path" }
Microsoft.PowerShell.Management\Push-Location -LiteralPath 'Variable:'
Set-Item -LiteralPath PID -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'provider-current-location-other-module-qualified-location-command-has-no-authority' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
Other.Module\Set-Location Variable:
Set-Item -LiteralPath PID -Value 1 -Force
'@

    Invoke-BraintrustLintFixture -Name 'shadowed-clv-function-is-not-builtin-alias' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
function clv { param($Name) Write-Output $Name }
clv PID
'@

    Invoke-BraintrustLintFixture -Name 'shadowed-rv-function-is-not-builtin-alias' -ExpectedExitCode 0 -ExpectedOutputPattern 'automatic-variable collision guard' -Content @'
function rv { param($Name) Write-Output $Name }
rv PID
'@
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'PowerShell automatic-variable collision guard regression PASS.' -ForegroundColor Green
