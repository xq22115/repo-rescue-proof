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

function Get-BraintrustUnqualifiedVariableNameFromText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $scopeMatch = [regex]::Match($Name, '^(?i:global|script|local|private):(.+)$')
    if ($scopeMatch.Success) {
        return $scopeMatch.Groups[1].Value
    }

    # Provider-qualified names such as env:PATH are not ordinary variable bindings
    # and are intentionally outside this automatic-variable guard.
    if ($Name.Contains(':')) {
        return $null
    }

    return $Name
}

function Get-BraintrustUnqualifiedVariableName {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.VariableExpressionAst]$VariableAst
    )

    return Get-BraintrustUnqualifiedVariableNameFromText -Name ([string]$VariableAst.VariablePath.UserPath)
}

function Test-BraintrustAutomaticVariableNameText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $unqualified = Get-BraintrustUnqualifiedVariableNameFromText -Name $Name
    if ($null -eq $unqualified) {
        return $false
    }

    return ($automaticVariableNames -contains $unqualified)
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

function Get-BraintrustStaticStringValues {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$ValueAst
    )

    if ($ValueAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return ,([string]$ValueAst.Value)
    }

    if ($ValueAst -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        if ($ValueAst.NestedExpressions.Count -eq 0) {
            return ,([string]$ValueAst.Value)
        }
        return @()
    }

    if ($ValueAst -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $values = @()
        foreach ($element in $ValueAst.Elements) {
            $values += @(Get-BraintrustStaticStringValues -ValueAst $element)
        }
        return $values
    }

    return @()
}

function Get-BraintrustAdjacentStaticStringValuesForVariableTarget {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.VariableExpressionAst]$VariableAst,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$CommandAst,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.AssignmentStatementAst[]]$AssignmentAsts,

        [Parameter(Mandatory = $true)]
        [string]$SourceText
    )

    # This is deliberately not general data-flow analysis. Resolve only an
    # unqualified variable whose nearest eligible plain '=' assignment appears
    # immediately before the Set-Variable command in source text. Any intervening
    # executable syntax, block delimiter, comment, or other statement causes this
    # helper to decline instead of guessing across control-flow boundaries.
    $variableName = [string]$VariableAst.VariablePath.UserPath
    if ([string]::IsNullOrWhiteSpace($variableName) -or $variableName.Contains(':')) {
        return @()
    }

    $candidate = $null
    if ($variableName -ieq 'name') {
        Write-Host ("[DEBUG-ADJ] targetType={0} command={1}:{2}-{3} assignments={4}" -f $VariableAst.GetType().FullName, $CommandAst.Extent.StartLineNumber, $CommandAst.Extent.StartOffset, $CommandAst.Extent.EndOffset, $AssignmentAsts.Count)
    }
    foreach ($assignmentAst in $AssignmentAsts) {
        if ($variableName -ieq 'name') {
            $leftName = if ($assignmentAst.Left -is [System.Management.Automation.Language.VariableExpressionAst]) { [string]$assignmentAst.Left.VariablePath.UserPath } else { '<non-variable>' }
            $rightType = if ($null -ne $assignmentAst.Right) { $assignmentAst.Right.GetType().FullName } else { '<null>' }
            Write-Host ("[DEBUG-ADJ] assignment left={0} op={1} rightType={2} extent={3}-{4}" -f $leftName, [string]$assignmentAst.Operator, $rightType, $assignmentAst.Extent.StartOffset, $assignmentAst.Extent.EndOffset)
            if ($assignmentAst.Right -is [System.Management.Automation.Language.PipelineBaseAst]) {
                $debugPure = $assignmentAst.Right.GetPureExpression()
                $debugPureType = if ($null -ne $debugPure) { $debugPure.GetType().FullName } else { '<null>' }
                $debugPureText = if ($null -ne $debugPure) { $debugPure.Extent.Text } else { '<null>' }
                Write-Host ("[DEBUG-ADJ] pureType={0} pureText={1}" -f $debugPureType, $debugPureText)
            }
        }
        if ($assignmentAst.Extent.EndOffset -gt $CommandAst.Extent.StartOffset) {
            continue
        }

        if ([string]$assignmentAst.Operator -ne 'Equals') {
            continue
        }

        if ($assignmentAst.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
            continue
        }

        $assignedName = [string]$assignmentAst.Left.VariablePath.UserPath
        if ([string]::IsNullOrWhiteSpace($assignedName) -or $assignedName.Contains(':') -or $assignedName -ine $variableName) {
            continue
        }

        if ($assignmentAst.Right -isnot [System.Management.Automation.Language.PipelineBaseAst]) {
            continue
        }

        $pureExpression = $assignmentAst.Right.GetPureExpression()
        if ($null -eq $pureExpression) {
            continue
        }

        $values = @(Get-BraintrustStaticStringValues -ValueAst $pureExpression)
        if ($values.Count -ne 1) {
            continue
        }

        $gapStart = [int]$assignmentAst.Extent.EndOffset
        $gapLength = [int]$CommandAst.Extent.StartOffset - $gapStart
        if ($gapStart -lt 0 -or $gapLength -lt 0 -or ($gapStart + $gapLength) -gt $SourceText.Length) {
            continue
        }

        $gap = $SourceText.Substring($gapStart, $gapLength)
        if ($gap -notmatch '^[\s;]*$') {
            continue
        }

        if ($null -eq $candidate -or $assignmentAst.Extent.EndOffset -gt $candidate.Assignment.Extent.EndOffset) {
            $candidate = [pscustomobject]@{
                Assignment = $assignmentAst
                Value = [string]$values[0]
            }
        }
    }

    if ($null -eq $candidate) {
        return @()
    }

    return ,([string]$candidate.Value)
}

function Get-BraintrustSetVariableNameTargets {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$CommandAst,

        [string[]]$DefinedFunctionNames = @()
    )

    $commandName = [string]$CommandAst.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($commandName)) {
        return @()
    }

    $leafName = $commandName
    $separatorIndex = $leafName.LastIndexOf('\')
    if ($separatorIndex -ge 0) {
        $leafName = $leafName.Substring($separatorIndex + 1)
    }

    $isCanonicalCommand = $leafName -ieq 'Set-Variable'
    $isBuiltinAlias = $leafName -ieq 'set' -or $leafName -ieq 'sv'
    if (-not $isCanonicalCommand -and -not $isBuiltinAlias) {
        return @()
    }

    # A locally-defined function named set/sv shadows the built-in alias. Do not
    # reinterpret that function call as Set-Variable. Dynamic Set-Alias shadowing
    # remains outside this small dependency-free static guard.
    if ($isBuiltinAlias -and ($DefinedFunctionNames -contains $leafName)) {
        return @()
    }

    $elements = @($CommandAst.CommandElements)
    $targets = @()
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            continue
        }

        if ($element.ParameterName -ine 'Name') {
            continue
        }

        if ($null -ne $element.Argument) {
            $targets += $element.Argument
            continue
        }

        $valueIndex = $index + 1
        if ($valueIndex -lt $elements.Count -and $elements[$valueIndex] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            $targets += $elements[$valueIndex]
            $index = $valueIndex
        }
    }

    if ($targets.Count -eq 0 -and $elements.Count -gt 1 -and $elements[1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
        # Only the unambiguous first positional argument is interpreted as -Name.
        # Once another parameter precedes it, parameter binding can be ambiguous and
        # this lightweight guard declines to guess.
        $targets += $elements[1]
    }

    return $targets
}

$files = Get-ChildItem -Path $Root -Filter "*.ps1" -File | Where-Object { $_.Name -ne "Test-Scripts.ps1" }
if (-not $files) {
    throw "No PowerShell scripts found under $Root"
}

$failed = $false
foreach ($file in $files) {
    $sourceText = [System.IO.File]::ReadAllText($file.FullName)
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
    $definedFunctionNames = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | ForEach-Object { [string]$_.Name })

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

    $unaryAsts = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.UnaryExpressionAst]
    }, $true)
    foreach ($unaryAst in $unaryAsts) {
        $tokenKind = [string]$unaryAst.TokenKind
        if ($tokenKind -notin @('PlusPlus', 'MinusMinus', 'PostfixPlusPlus', 'PostfixMinusMinus')) {
            continue
        }

        if ($unaryAst.Child -is [System.Management.Automation.Language.VariableExpressionAst] -and
            (Test-BraintrustAutomaticVariableCollision -VariableAst $unaryAst.Child)) {
            $collisions += [pscustomobject]@{
                Kind = 'unary-write'
                Variable = [string]$unaryAst.Child.VariablePath.UserPath
                Extent = $unaryAst.Child.Extent
            }
        }
    }

    $commandAsts = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)
    foreach ($commandAst in $commandAsts) {
        foreach ($targetAst in (Get-BraintrustSetVariableNameTargets -CommandAst $commandAst -DefinedFunctionNames $definedFunctionNames)) {
            foreach ($literalName in (Get-BraintrustStaticStringValues -ValueAst $targetAst)) {
                if (Test-BraintrustAutomaticVariableNameText -Name $literalName) {
                    $collisions += [pscustomobject]@{
                        Kind = 'set-variable'
                        Variable = [string]$literalName
                        Extent = $targetAst.Extent
                    }
                }
            }

            if ($targetAst -is [System.Management.Automation.Language.VariableExpressionAst]) {
                foreach ($literalName in (Get-BraintrustAdjacentStaticStringValuesForVariableTarget -VariableAst $targetAst -CommandAst $commandAst -AssignmentAsts @($assignmentAsts) -SourceText $sourceText)) {
                    if (Test-BraintrustAutomaticVariableNameText -Name $literalName) {
                        $collisions += [pscustomobject]@{
                            Kind = 'set-variable-adjacent-constant'
                            Variable = [string]$literalName
                            Extent = $targetAst.Extent
                        }
                    }
                }
            }
        }
    }

    if ($collisions.Count -gt 0) {
        $failed = $true
        Write-Host "[FAIL] $($file.Name) automatic-variable collision" -ForegroundColor Red
        foreach ($collision in $collisions) {
            Write-Host ("  Line {0}, Column {1}: {2} variable '{3}' collides case-insensitively with a PowerShell automatic variable" -f $collision.Extent.StartLineNumber, $collision.Extent.StartColumnNumber, $collision.Kind, $collision.Variable)
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
