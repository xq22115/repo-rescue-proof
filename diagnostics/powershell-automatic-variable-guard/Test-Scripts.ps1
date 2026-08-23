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
    # immediately before the variable-name command in source text. Any intervening
    # executable syntax, block delimiter, comment, or other statement causes this
    # helper to decline instead of guessing across control-flow boundaries.
    $variableName = [string]$VariableAst.VariablePath.UserPath
    if ([string]::IsNullOrWhiteSpace($variableName) -or $variableName.Contains(':')) {
        return @()
    }

    $candidate = $null
    foreach ($assignmentAst in $AssignmentAsts) {
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

        $valueExpression = $null
        if ($assignmentAst.Right -is [System.Management.Automation.Language.CommandExpressionAst]) {
            # Native Windows PowerShell 5.1/PowerShell 7 falsification showed that
            # a plain assignment such as $name = 'PID' exposes the RHS as a
            # CommandExpressionAst. Its Expression property is the literal AST.
            $valueExpression = $assignmentAst.Right.Expression
        }
        elseif ($assignmentAst.Right -is [System.Management.Automation.Language.PipelineBaseAst]) {
            $valueExpression = $assignmentAst.Right.GetPureExpression()
        }

        if ($null -eq $valueExpression) {
            continue
        }

        $values = @(Get-BraintrustStaticStringValues -ValueAst $valueExpression)
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

function Get-BraintrustVariableCommandParameterSpec {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Set-Variable', 'New-Variable')]
        [string]$CommandName
    )

    # Keep this deliberately bounded to the static parameter surface needed to
    # locate positional -Name arguments for these two cmdlets. The switch/value
    # distinction lets the guard recognize forms such as `New-Variable -Force PID`
    # without trying to become a general PowerShell parameter binder.
    $switches = @('Force', 'PassThru', 'WhatIf', 'Confirm', 'Verbose', 'Debug')
    $values = @(
        'Name', 'Value', 'Description', 'Option', 'Visibility', 'Scope',
        'ErrorAction', 'ErrorVariable', 'WarningAction', 'WarningVariable',
        'InformationAction', 'InformationVariable', 'OutVariable', 'OutBuffer',
        'PipelineVariable', 'ProgressAction'
    )
    if ($CommandName -eq 'Set-Variable') {
        $values += @('Include', 'Exclude')
    }

    $result = @()
    foreach ($name in $switches) {
        $result += [pscustomobject]@{ Name = $name; IsSwitch = $true }
    }
    foreach ($name in $values) {
        $result += [pscustomobject]@{ Name = $name; IsSwitch = $false }
    }
    return $result
}

function Resolve-BraintrustVariableCommandParameter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParameterName,

        [Parameter(Mandatory = $true)]
        [object[]]$ParameterSpec
    )

    if ([string]::IsNullOrWhiteSpace($ParameterName)) {
        return $null
    }

    $matches = @($ParameterSpec | Where-Object { $_.Name.StartsWith($ParameterName, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -ne 1) {
        return $null
    }
    return $matches[0]
}

function Get-BraintrustVariableNameWriteTargets {
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
    $separatorIndex = $leafName.LastIndexOf([char]92)
    if ($separatorIndex -ge 0) {
        $leafName = $leafName.Substring($separatorIndex + 1)
    }

    $canonicalCommand = $null
    $writeKind = $null
    $isBuiltinAlias = $false
    if ($leafName -ieq 'Set-Variable') {
        $canonicalCommand = 'Set-Variable'
        $writeKind = 'set-variable'
    }
    elseif ($leafName -ieq 'set' -or $leafName -ieq 'sv') {
        $canonicalCommand = 'Set-Variable'
        $writeKind = 'set-variable'
        $isBuiltinAlias = $true
    }
    elseif ($leafName -ieq 'New-Variable') {
        $canonicalCommand = 'New-Variable'
        $writeKind = 'new-variable'
    }
    elseif ($leafName -ieq 'nv') {
        $canonicalCommand = 'New-Variable'
        $writeKind = 'new-variable'
        $isBuiltinAlias = $true
    }
    else {
        return @()
    }

    # Locally-defined functions can shadow built-in aliases such as set/sv/nv. Do
    # not reinterpret those function calls as variable cmdlets. Dynamic Set-Alias
    # shadowing remains outside this small dependency-free static guard.
    if ($isBuiltinAlias -and ($DefinedFunctionNames -contains $leafName)) {
        return @()
    }

    $elements = @($CommandAst.CommandElements)
    $parameterSpec = @(Get-BraintrustVariableCommandParameterSpec -CommandName $canonicalCommand)
    $targets = @()
    $explicitNameObserved = $false

    # First bind an explicit -Name (including a unique abbreviation). This is
    # independent of where other named parameters appear in the command.
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            continue
        }
        $resolved = Resolve-BraintrustVariableCommandParameter -ParameterName ([string]$element.ParameterName) -ParameterSpec $parameterSpec
        if ($null -eq $resolved -or $resolved.Name -ne 'Name') {
            continue
        }

        $explicitNameObserved = $true
        if ($null -ne $element.Argument) {
            $targets += $element.Argument
            continue
        }

        $valueIndex = $index + 1
        if ($valueIndex -lt $elements.Count -and $elements[$valueIndex] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            $targets += $elements[$valueIndex]
        }
    }

    if (-not $explicitNameObserved) {
        # Locate position 0 even when named parameters precede it. Known switch
        # parameters do not consume the next element; known value parameters do.
        # Unknown or ambiguous parameter prefixes make the remaining binder state
        # uncertain, so decline positional inference instead of guessing.
        $skipNextValue = $false
        for ($index = 1; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            if ($skipNextValue) {
                if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                    $skipNextValue = $false
                    continue
                }
                # A named parameter where a value was expected is invalid/ambiguous
                # runtime syntax. Do not infer a positional Name after this point.
                break
            }

            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                $resolved = Resolve-BraintrustVariableCommandParameter -ParameterName ([string]$element.ParameterName) -ParameterSpec $parameterSpec
                if ($null -eq $resolved) {
                    break
                }
                if (-not $resolved.IsSwitch -and $null -eq $element.Argument) {
                    $skipNextValue = $true
                }
                continue
            }

            $targets += $element
            break
        }
    }

    $result = @()
    foreach ($target in $targets) {
        $result += [pscustomobject]@{
            Kind = $writeKind
            TargetAst = $target
        }
    }
    return $result
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
        foreach ($writeTarget in (Get-BraintrustVariableNameWriteTargets -CommandAst $commandAst -DefinedFunctionNames $definedFunctionNames)) {
            $targetAst = $writeTarget.TargetAst
            $writeKind = [string]$writeTarget.Kind
            foreach ($literalName in (Get-BraintrustStaticStringValues -ValueAst $targetAst)) {
                if (Test-BraintrustAutomaticVariableNameText -Name $literalName) {
                    $collisions += [pscustomobject]@{
                        Kind = $writeKind
                        Variable = [string]$literalName
                        Extent = $targetAst.Extent
                    }
                }
            }

            if ($targetAst -is [System.Management.Automation.Language.VariableExpressionAst]) {
                foreach ($literalName in (Get-BraintrustAdjacentStaticStringValuesForVariableTarget -VariableAst $targetAst -CommandAst $commandAst -AssignmentAsts @($assignmentAsts) -SourceText $sourceText)) {
                    if (Test-BraintrustAutomaticVariableNameText -Name $literalName) {
                        $collisions += [pscustomobject]@{
                            Kind = ($writeKind + '-adjacent-constant')
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