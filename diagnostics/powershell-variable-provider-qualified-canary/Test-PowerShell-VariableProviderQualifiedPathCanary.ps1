$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$cases = @(
    @{ Name = 'drive-qualified'; Template = 'Variable:{0}' },
    @{ Name = 'provider-qualified'; Template = 'Variable::{0}' },
    @{ Name = 'module-provider-qualified'; Template = 'Microsoft.PowerShell.Core\Variable::{0}' }
)

$results = @()
foreach ($case in $cases) {
    $suffix = [Guid]::NewGuid().ToString('N')
    $setName = "braintrustProviderSet_$suffix"
    $clearName = "braintrustProviderClear_$suffix"
    $removeName = "braintrustProviderRemove_$suffix"

    try {
        Set-Variable -Name $setName -Value 'before'
        $setPath = [string]::Format($case.Template, $setName)
        Microsoft.PowerShell.Management\Set-Item -LiteralPath $setPath -Value 'after'
        $after = Get-Variable -Name $setName -ValueOnly
        if ($after -ne 'after') {
            throw "Set-Item did not mutate through $($case.Name): path=$setPath value=$after"
        }

        Set-Variable -Name $clearName -Value 'before'
        $clearPath = [string]::Format($case.Template, $clearName)
        Microsoft.PowerShell.Management\Clear-Item -LiteralPath $clearPath
        $cleared = Get-Variable -Name $clearName -ValueOnly
        if ($null -ne $cleared) {
            throw "Clear-Item did not clear through $($case.Name): path=$clearPath value=$cleared"
        }

        Set-Variable -Name $removeName -Value 'before'
        $removePath = [string]::Format($case.Template, $removeName)
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $removePath
        if ($null -ne (Get-Variable -Name $removeName -ErrorAction SilentlyContinue)) {
            throw "Remove-Item did not remove through $($case.Name): path=$removePath"
        }

        $protectedPath = [string]::Format($case.Template, 'PID')
        $protectedFailed = $false
        try {
            Microsoft.PowerShell.Management\Set-Item -LiteralPath $protectedPath -Value 1 -ErrorAction Stop
        }
        catch {
            $protectedFailed = $true
        }
        if (-not $protectedFailed) {
            throw "Protected automatic variable unexpectedly mutated through $($case.Name): path=$protectedPath"
        }

        $results += [pscustomobject]@{
            case = $case.Name
            set = $true
            clear = $true
            remove = $true
            protectedAutomaticVariableRejected = $true
        }
    }
    finally {
        Remove-Variable -Name $setName,$clearName,$removeName -ErrorAction SilentlyContinue
    }
}

# Wildcard semantics are tested only for -Path, not -LiteralPath.
$wildSuffix = [Guid]::NewGuid().ToString('N')
$wildName = "braintrustProviderWildcard_$wildSuffix"
Set-Variable -Name $wildName -Value 'before'
try {
    $wildPrefix = $wildName.Substring(0, $wildName.Length - 6)
    Microsoft.PowerShell.Management\Set-Item -Path ("Variable::{0}*" -f $wildPrefix) -Value 'after'
    if ((Get-Variable -Name $wildName -ValueOnly) -ne 'after') {
        throw 'Provider-qualified -Path wildcard did not select the ordinary variable.'
    }
}
finally {
    Remove-Variable -Name $wildName -ErrorAction SilentlyContinue
}

# Falsify the current static guard itself. The existing guard recognizes the
# drive-qualified Variable: form, but its parser currently treats Variable::PID
# as target ':PID' and does not recognize the module-qualified provider form.
$lintScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'powershell-automatic-variable-guard\Test-Scripts.ps1'
if (-not (Test-Path -LiteralPath $lintScript -PathType Leaf)) {
    throw "Missing public Test-Scripts.ps1 at $lintScript"
}
$currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$shellPath = $currentProcess.MainModule.FileName
if ([string]::IsNullOrWhiteSpace($shellPath) -or -not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
    throw 'Could not resolve current PowerShell executable for guard-bypass falsification.'
}
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("braintrust-provider-qualified-guard-bypass-{0}" -f [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tempRoot -Force)
$guardBypassObserved = $false
try {
    $fixturePath = Join-Path $tempRoot 'fixture.ps1'
    Set-Content -LiteralPath $fixturePath -Encoding UTF8 -Value @'
Microsoft.PowerShell.Management\Set-Item -LiteralPath 'Variable::PID' -Value 1 -Force
Microsoft.PowerShell.Management\Clear-Item -LiteralPath 'Microsoft.PowerShell.Core\Variable::Error' -Force
'@
    $guardOutput = (& $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $lintScript -Root $tempRoot 2>&1 | Out-String)
    $guardExit = $LASTEXITCODE
    if ($guardExit -ne 0) {
        throw "Expected current guard to expose the provider-qualified bypass before the canonical fix, but it exited $guardExit. Output: $guardOutput"
    }
    $guardBypassObserved = $true
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$receipt = [ordered]@{
    component = 'public-powershell-variable-provider-qualified-path-canary'
    schemaVersion = 2
    osVersion = [Environment]::OSVersion.VersionString
    psEdition = $PSVersionTable.PSEdition
    psVersion = $PSVersionTable.PSVersion.ToString()
    results = $results
    providerQualifiedWildcardAccepted = $true
    currentStaticGuardProviderQualifiedBypassObserved = $guardBypassObserved
    automaticVariableMutationAccepted = $false
}
$receipt | ConvertTo-Json -Depth 8
Write-Host 'POWERSHELL_VARIABLE_PROVIDER_QUALIFIED_PATH_CANARY_PASS'
