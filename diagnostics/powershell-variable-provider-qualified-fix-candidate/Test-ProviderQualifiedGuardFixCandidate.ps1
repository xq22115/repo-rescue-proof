param(
    [Parameter(Mandatory = $true)]
    [string]$LintScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$shellPath = $currentProcess.MainModule.FileName
if ([string]::IsNullOrWhiteSpace($shellPath) -or -not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
    throw 'Could not resolve current PowerShell executable.'
}
if (-not (Test-Path -LiteralPath $LintScript -PathType Leaf)) {
    throw "Missing candidate linter at $LintScript"
}

function Invoke-LintFixture {
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [bool]$ExpectFailure,
        [string]$ExpectedText = ''
    )

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("braintrust-provider-qualified-fix-{0}-{1}" -f $Name, [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $root -Force)
    try {
        $fixture = Join-Path $root 'fixture.ps1'
        [System.IO.File]::WriteAllText($fixture, $Source, [System.Text.UTF8Encoding]::new($false))
        $output = (& $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $LintScript -Root $root 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        if ($ExpectFailure) {
            if ($exitCode -eq 0) {
                throw "Fixture '$Name' unexpectedly passed. Output: $output"
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedText) -and $output.IndexOf($ExpectedText, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                throw "Fixture '$Name' failed without expected text '$ExpectedText'. Output: $output"
            }
        }
        else {
            if ($exitCode -ne 0) {
                throw "Fixture '$Name' unexpectedly failed with exit $exitCode. Output: $output"
            }
        }
        Write-Host ("[PASS] {0}" -f $Name)
    }
    finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$management = 'Microsoft.PowerShell.Management' + [char]92
Invoke-LintFixture -Name 'drive-qualified' -ExpectFailure $true -ExpectedText 'Variable:PID' -Source ($management + "Set-Item -LiteralPath 'Variable:PID' -Value 1 -Force")
Invoke-LintFixture -Name 'provider-qualified' -ExpectFailure $true -ExpectedText 'Variable::PID' -Source ($management + "Set-Item -LiteralPath 'Variable::PID' -Value 1 -Force")
Invoke-LintFixture -Name 'module-provider-qualified' -ExpectFailure $true -ExpectedText 'Microsoft.PowerShell.Core\Variable::Error' -Source ($management + "Clear-Item -LiteralPath 'Microsoft.PowerShell.Core\Variable::Error' -Force")
Invoke-LintFixture -Name 'provider-qualified-scoped' -ExpectFailure $true -ExpectedText 'Variable::global:PID' -Source ($management + "Remove-Item -LiteralPath 'Variable::global:PID' -Force")
Invoke-LintFixture -Name 'provider-qualified-wildcard' -ExpectFailure $true -ExpectedText 'Variable::P*' -Source ($management + "Set-Item -Path 'Variable::P*' -Value 1 -Force")
Invoke-LintFixture -Name 'module-provider-qualified-wildcard' -ExpectFailure $true -ExpectedText 'Microsoft.PowerShell.Core\Variable::P*' -Source ($management + "Set-Item -Path 'Microsoft.PowerShell.Core\Variable::P*' -Value 1 -Force")

# LiteralPath must remain literal rather than inheriting -Path wildcard semantics.
Invoke-LintFixture -Name 'provider-qualified-literal-wildcard' -ExpectFailure $false -Source ($management + "Set-Item -LiteralPath 'Variable::P*' -Value 1 -Force")

# A provider in another module whose leaf happens to be named Variable is not the
# built-in Microsoft.PowerShell.Core Variable provider. Do not grant it authority.
Invoke-LintFixture -Name 'other-module-same-provider-leaf' -ExpectFailure $false -Source ($management + "Set-Item -LiteralPath 'Contoso.Module\Variable::PID' -Value 1 -Force")
Invoke-LintFixture -Name 'filesystem-lookalike' -ExpectFailure $false -Source ($management + "Set-Item -LiteralPath '.\Variable::PID.txt' -Value 1 -Force")

$receipt = [ordered]@{
    component = 'public-powershell-variable-provider-qualified-fix-candidate'
    schemaVersion = 1
    osVersion = [Environment]::OSVersion.VersionString
    psEdition = [string]$PSVersionTable.PSEdition
    psVersion = [string]$PSVersionTable.PSVersion
    providerQualifiedAutomaticVariableVetoAccepted = $true
    moduleProviderQualifiedAutomaticVariableVetoAccepted = $true
    scopedProviderQualifiedAutomaticVariableVetoAccepted = $true
    providerQualifiedWildcardVetoAccepted = $true
    literalPathWildcardSeparationAccepted = $true
    otherModuleSameLeafNotAcceptedAsBuiltinVariableProvider = $true
}
$receipt | ConvertTo-Json -Depth 8
Write-Host 'POWERSHELL_VARIABLE_PROVIDER_QUALIFIED_FIX_CANDIDATE_PASS'
