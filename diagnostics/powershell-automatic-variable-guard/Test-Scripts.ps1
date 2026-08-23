param(
    [string]$Root = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# PowerShell variable names are case-insensitive. Keep a portability-oriented union
# of Windows PowerShell 5.1 and PowerShell 7 automatic-variable names so a script
# cannot pass parsing on one shell and then collide with a read-only/runtime-owned
# variable (for example $isWindows vs. $IsWindows) on another.
[string[]]$automaticVariableNames = @(
    '$', '?', '^', '_',
    'args',
    'ConsoleFileName',
    'EnabledExperimentalFeatures',
    'Error',
    'Event',
    'EventArgs',
    'EventSubscriber',
    'ExecutionContext',
    'false',
    'foreach',
    'HOME',
    'Host',
    'input',
    'IsCoreCLR',
    'IsLinux',
    'IsMacOS',
    'IsWindows',
    'LASTEXITCODE',
    'Matches',
    'MyInvocation',
    'NestedPromptLevel',
    'null',
    'PID',
    'PROFILE',
    'PSBoundParameters',
    'PSCmdlet',
    'PSCommandPath',
    'PSCulture',
    'PSDebugContext',
    'PSEdition',
    'PSHOME',
    'PSItem',
    'PSScriptRoot',
    'PSSenderInfo',
    'PSUICulture',
    'PSVersionTable',
    'PWD',
    'Sender',
    'ShellId',
    'StackTrace',
    'switch',
    'this',
    'true'
)

function Get-BraintrustUnqualifiedVariableName {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.VariableExpressionAst]$VariableAst
    )

    $name = [string]$VariableAst.VariablePath.UserPath
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }

    $scopeMatch = [regex]::Match($name, '^(?i:global|script|local|private):(.+)$')
    if ($scopeMatch.Success) {
        return $scopeMatch.Groups[1].Value
    }

    # Provider-qualified paths such as env:PATH are not ordinary variables and
    # are intentionally outside this automatic-variable guard.
    if ($name.Contains(':')) {
        return $null
    }

    return $name
}

function Test-BraintrustAutomaticVariableCollision {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.VariableExpressionAst]$VariableAst
    )

    $name = Get-BraintrustUnqualifiedVariableName -VariableAst $VariableAst
    if ($null -eq $name) {
        return $false
    }

    return ($automaticVariableNames -contains $name)
}

function Get-BraintrustDirectAssignmentVariables {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$TargetAst
    )

    if ($TargetAst -is [System.Management.Automation.Language.VariableExpressionAst]) {
        return ,$TargetAst
    }

    if ($TargetAst -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $result = @()
        foreach ($element in $TargetAst.Elements) {
            if ($element -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $result += $element
            }
        }
        return $result
    }

    # Member/index assignments (for example $obj.Property = 1) write through the
    # member expression, not to the variable itself, so do not descend into them.
    return @()
}

$files = Get-ChildItem -Path $Root -Filter "*.ps1" -File | Where-Object { $_.Name -ne "Test-Scripts.ps1" }
if (-not $files) {
    throw "No PowerShell scripts found under $Root"
}

$failed = $false
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)

    if ($errors.Count -gt 0) {
        $failed = $true
        Write-Host "[FAIL] $($file.Name)" -ForegroundColor Red
        foreach ($err in $errors) {
            Write-Host ("  Line {0}, Column {1}: {2}" -f $err.Extent.StartLineNumber, $err.Extent.StartColumnNumber, $err.Message)
        }
        continue
    }

    $collisions = @()

    $parameterAsts = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ParameterAst]
    }, $true)
    foreach ($parameterAst in $parameterAsts) {
        if (Test-BraintrustAutomaticVariableCollision -VariableAst $parameterAst.Name) {
            $collisions += [pscustomobject]@{
                Kind = 'parameter'
                Variable = [string]$parameterAst.Name.VariablePath.UserPath
                Extent = $parameterAst.Name.Extent
            }
        }
    }

    $assignmentAsts = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true)
    foreach ($assignmentAst in $assignmentAsts) {
        foreach ($variableAst in (Get-BraintrustDirectAssignmentVariables -TargetAst $assignmentAst.Left)) {
            if (Test-BraintrustAutomaticVariableCollision -VariableAst $variableAst) {
                $collisions += [pscustomobject]@{
                    Kind = 'assignment'
                    Variable = [string]$variableAst.VariablePath.UserPath
                    Extent = $variableAst.Extent
                }
            }
        }
    }

    $forEachAsts = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst]
    }, $true)
    foreach ($forEachAst in $forEachAsts) {
        if (($null -ne $forEachAst.Variable) -and (Test-BraintrustAutomaticVariableCollision -VariableAst $forEachAst.Variable)) {
            $collisions += [pscustomobject]@{
                Kind = 'foreach-variable'
                Variable = [string]$forEachAst.Variable.VariablePath.UserPath
                Extent = $forEachAst.Variable.Extent
            }
        }
    }

    if ($collisions.Count -gt 0) {
        $failed = $true
        Write-Host "[FAIL] $($file.Name) automatic-variable collision" -ForegroundColor Red
        foreach ($collision in $collisions) {
            Write-Host ("  Line {0}, Column {1}: {2} '${3}' collides case-insensitively with a PowerShell automatic variable" -f $collision.Extent.StartLineNumber, $collision.Extent.StartColumnNumber, $collision.Kind, $collision.Variable)
        }
        continue
    }

    Write-Host "[PASS] $($file.Name)" -ForegroundColor Green
}

if ($failed) {
    exit 1
}

$resolvedRoot = (Resolve-Path -LiteralPath $Root).Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
$resolvedCanonicalRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
if ($resolvedRoot -eq $resolvedCanonicalRoot) {
    $guardRegression = Join-Path $PSScriptRoot 'Test-PowerShell-AutomaticVariableGuard.ps1'
    if (-not (Test-Path -LiteralPath $guardRegression -PathType Leaf)) {
        throw "Missing automatic-variable guard regression at $guardRegression"
    }
    & $guardRegression
}

Write-Host "All PowerShell scripts parsed successfully and passed the automatic-variable collision guard."
exit 0
