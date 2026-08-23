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
        [ValidateSet('Set-Variable', 'New-Variable', 'Clear-Variable', 'Remove-Variable')]
        [string]$CommandName
    )

    # Keep this deliberately bounded to the static parameter surface needed to
    # locate positional -Name arguments for these bounded variable cmdlets. The switch/value
    # distinction lets the guard recognize forms such as `New-Variable -Force PID`
    # without trying to become a general PowerShell parameter binder.
    $switches = @('Force', 'WhatIf', 'Confirm', 'Verbose', 'Debug')
    if ($CommandName -ne 'Remove-Variable') {
        $switches += 'PassThru'
    }

    $values = @(
        'Name', 'Scope',
        'ErrorAction', 'ErrorVariable', 'WarningAction', 'WarningVariable',
        'InformationAction', 'InformationVariable', 'OutVariable', 'OutBuffer',
        'PipelineVariable', 'ProgressAction'
    )
    if ($CommandName -eq 'Set-Variable') {
        $values += @('Value', 'Description', 'Option', 'Visibility', 'Include', 'Exclude')
    }
    elseif ($CommandName -eq 'New-Variable') {
        $values += @('Value', 'Description', 'Option', 'Visibility')
    }
    elseif ($CommandName -eq 'Clear-Variable' -or $CommandName -eq 'Remove-Variable') {
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

function Get-BraintrustEnclosingStatementContainer {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    $current = $Ast
    while ($null -ne $current) {
        if ($current -is [System.Management.Automation.Language.StatementBlockAst] -or
            $current -is [System.Management.Automation.Language.NamedBlockAst]) {
            return $current
        }
        $current = $current.Parent
    }
    return $null
}

function Test-BraintrustBuiltinAliasDefinitelyShadowed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AliasName,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$CommandAst,

        [System.Management.Automation.Language.FunctionDefinitionAst[]]$FunctionDefinitionAsts = @()
    )

    # Function declarations execute as statements; a later declaration must not
    # retroactively excuse an earlier use of a built-in alias. To avoid guessing
    # across conditional/control-flow boundaries, only accept a matching function
    # definition that has already completed in the same statement container.
    $commandContainer = Get-BraintrustEnclosingStatementContainer -Ast $CommandAst
    if ($null -eq $commandContainer) {
        return $false
    }

    foreach ($functionAst in $FunctionDefinitionAsts) {
        if ([string]$functionAst.Name -ine $AliasName) {
            continue
        }
        if ($functionAst.Extent.EndOffset -ge $CommandAst.Extent.StartOffset) {
            continue
        }
        $functionContainer = Get-BraintrustEnclosingStatementContainer -Ast $functionAst
        if ($null -ne $functionContainer -and [object]::ReferenceEquals($functionContainer, $commandContainer)) {
            return $true
        }
    }
    return $false
}

function Get-BraintrustVariableNameWriteTargets {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$CommandAst,

        [System.Management.Automation.Language.FunctionDefinitionAst[]]$FunctionDefinitionAsts = @()
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
    elseif ($leafName -ieq 'Clear-Variable') {
        $canonicalCommand = 'Clear-Variable'
        $writeKind = 'clear-variable'
    }
    elseif ($leafName -ieq 'clv') {
        $canonicalCommand = 'Clear-Variable'
        $writeKind = 'clear-variable'
        $isBuiltinAlias = $true
    }
    elseif ($leafName -ieq 'Remove-Variable') {
        $canonicalCommand = 'Remove-Variable'
        $writeKind = 'remove-variable'
    }
    elseif ($leafName -ieq 'rv') {
        $canonicalCommand = 'Remove-Variable'
        $writeKind = 'remove-variable'
        $isBuiltinAlias = $true
    }
    else {
        return @()
    }

    # Locally-defined functions can shadow built-in aliases such as set/sv/nv/clv/rv. Do
    # not reinterpret those function calls as variable cmdlets. Dynamic Set-Alias
    # shadowing remains outside this small dependency-free static guard.
    if ($isBuiltinAlias -and (Test-BraintrustBuiltinAliasDefinitelyShadowed -AliasName $leafName -CommandAst $CommandAst -FunctionDefinitionAsts $FunctionDefinitionAsts)) {
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

function Get-BraintrustProviderItemCommandParameterSpec {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Set-Item', 'Clear-Item', 'Remove-Item')]
        [string]$CommandName
    )

    # Bounded parameter model used only to locate position-0 Path when common
    # named parameters precede it. Unknown/ambiguous prefixes make inference stop.
    $switches = @('Force', 'WhatIf', 'Confirm', 'Verbose', 'Debug')
    if ($CommandName -eq 'Set-Item') {
        $switches += 'PassThru'
    }
    if ($CommandName -eq 'Remove-Item') {
        $switches += 'Recurse'
    }

    $values = @(
        'Path', 'LiteralPath', 'Filter', 'Include', 'Exclude', 'Credential',
        'ErrorAction', 'ErrorVariable', 'WarningAction', 'WarningVariable',
        'InformationAction', 'InformationVariable', 'OutVariable', 'OutBuffer',
        'PipelineVariable', 'ProgressAction'
    )
    if ($CommandName -eq 'Set-Item') {
        $values += 'Value'
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

function Get-BraintrustProviderItemMutationTargets {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$CommandAst,

        [System.Management.Automation.Language.FunctionDefinitionAst[]]$FunctionDefinitionAsts = @()
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
    if ($leafName -ieq 'Set-Item') {
        $canonicalCommand = 'Set-Item'
        $writeKind = 'set-item-variable-provider'
    }
    elseif ($leafName -ieq 'si') {
        $canonicalCommand = 'Set-Item'
        $writeKind = 'set-item-variable-provider'
        $isBuiltinAlias = $true
    }
    elseif ($leafName -ieq 'Clear-Item') {
        $canonicalCommand = 'Clear-Item'
        $writeKind = 'clear-item-variable-provider'
    }
    elseif ($leafName -ieq 'cli') {
        $canonicalCommand = 'Clear-Item'
        $writeKind = 'clear-item-variable-provider'
        $isBuiltinAlias = $true
    }
    elseif ($leafName -ieq 'Remove-Item') {
        $canonicalCommand = 'Remove-Item'
        $writeKind = 'remove-item-variable-provider'
    }
    elseif ($leafName -ieq 'ri') {
        $canonicalCommand = 'Remove-Item'
        $writeKind = 'remove-item-variable-provider'
        $isBuiltinAlias = $true
    }
    else {
        return @()
    }

    # Do not reinterpret a definitely shadowed built-in alias as a provider cmdlet.
    if ($isBuiltinAlias -and (Test-BraintrustBuiltinAliasDefinitelyShadowed -AliasName $leafName -CommandAst $CommandAst -FunctionDefinitionAsts $FunctionDefinitionAsts)) {
        return @()
    }

    $elements = @($CommandAst.CommandElements)
    $parameterSpec = @(Get-BraintrustProviderItemCommandParameterSpec -CommandName $canonicalCommand)
    $targets = @()
    $explicitPathObserved = $false

    # Prefer an explicit -Path/-LiteralPath (including unique abbreviations).
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            continue
        }
        $resolved = Resolve-BraintrustVariableCommandParameter -ParameterName ([string]$element.ParameterName) -ParameterSpec $parameterSpec
        if ($null -eq $resolved -or $resolved.Name -notin @('Path', 'LiteralPath')) {
            continue
        }

        $explicitPathObserved = $true
        $targetAst = $element.Argument
        if ($null -eq $targetAst) {
            $valueIndex = $index + 1
            if ($valueIndex -lt $elements.Count -and $elements[$valueIndex] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                $targetAst = $elements[$valueIndex]
            }
        }
        if ($null -ne $targetAst) {
            $targets += [pscustomobject]@{
                Kind = $writeKind
                TargetAst = $targetAst
                LiteralPath = ($resolved.Name -eq 'LiteralPath')
            }
        }
    }

    if (-not $explicitPathObserved) {
        # Locate the position-0 Path while respecting a small known parameter model.
        $skipNextValue = $false
        for ($index = 1; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            if ($skipNextValue) {
                if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                    $skipNextValue = $false
                    continue
                }
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

            $targets += [pscustomobject]@{
                Kind = $writeKind
                TargetAst = $element
                LiteralPath = $false
            }
            break
        }
    }

    return $targets
}

function Test-BraintrustVariableProviderPathTargetsAutomaticVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathText,

        [Parameter(Mandatory = $true)]
        [bool]$LiteralPath
    )

    $providerMatch = [regex]::Match($PathText, '^(?i:variable):(?<target>.*)$')
    if (-not $providerMatch.Success) {
        return $false
    }

    $target = [string]$providerMatch.Groups['target'].Value
    $target = $target.TrimStart([char]92, [char]47)
    if ([string]::IsNullOrWhiteSpace($target)) {
        return $false
    }

    # Native Windows 2022/2025 probes show provider-qualified scoped forms such
    # as Variable:global:PID reach the same protected automatic-variable surface.
    $scopeMatch = [regex]::Match($target, '^(?i:global|script|local|private):(?<name>.+)$')
    if ($scopeMatch.Success) {
        $target = [string]$scopeMatch.Groups['name'].Value
    }

    if ($LiteralPath) {
        return (Test-BraintrustAutomaticVariableNameText -Name $target)
    }

    # -Path is wildcard-aware. If a static provider pattern can select any known
    # automatic variable, fail closed. LiteralPath intentionally does not do this.
    try {
        $pattern = [System.Management.Automation.WildcardPattern]::new(
            $target,
            [System.Management.Automation.WildcardOptions]::IgnoreCase
        )
    }
    catch {
        return $false
    }

    foreach ($automaticName in $automaticVariableNames) {
        if ($pattern.IsMatch([string]$automaticName)) {
            return $true
        }
    }
    return $false
}

function Get-BraintrustStaticSetLocationPath {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$CommandAst
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
    if ($leafName -ine 'Set-Location') {
        return @()
    }

    $elements = @($CommandAst.CommandElements)
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            continue
        }
        $parameterName = [string]$element.ParameterName
        if ($parameterName -ine 'Path' -and $parameterName -ine 'LiteralPath') {
            return @()
        }
        $targetAst = $element.Argument
        if ($null -eq $targetAst) {
            $valueIndex = $index + 1
            if ($valueIndex -ge $elements.Count -or $elements[$valueIndex] -is [System.Management.Automation.Language.CommandParameterAst]) {
                return @()
            }
            $targetAst = $elements[$valueIndex]
        }
        $values = @(Get-BraintrustStaticStringValues -ValueAst $targetAst)
        if ($values.Count -eq 1) {
            return ,([string]$values[0])
        }
        return @()
    }

    # Keep positional inference deliberately narrow: command + one static path.
    if ($elements.Count -eq 2 -and $elements[1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
        $values = @(Get-BraintrustStaticStringValues -ValueAst $elements[1])
        if ($values.Count -eq 1) {
            return ,([string]$values[0])
        }
    }
    return @()
}

function Test-BraintrustImmediatelyInVariableProviderLocation {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$CommandAst,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst[]]$CommandAsts,

        [Parameter(Mandatory = $true)]
        [string]$SourceText
    )

    $commandContainer = Get-BraintrustEnclosingStatementContainer -Ast $CommandAst
    if ($null -eq $commandContainer) {
        return $false
    }

    foreach ($candidate in $CommandAsts) {
        if ($candidate.Extent.EndOffset -gt $CommandAst.Extent.StartOffset) {
            continue
        }
        $candidateContainer = Get-BraintrustEnclosingStatementContainer -Ast $candidate
        if ($null -eq $candidateContainer -or -not [object]::ReferenceEquals($candidateContainer, $commandContainer)) {
            continue
        }
        $paths = @(Get-BraintrustStaticSetLocationPath -CommandAst $candidate)
        if ($paths.Count -ne 1) {
            continue
        }

        $gapStart = [int]$candidate.Extent.EndOffset
        $gapLength = [int]$CommandAst.Extent.StartOffset - $gapStart
        if ($gapStart -lt 0 -or $gapLength -lt 0 -or ($gapStart + $gapLength) -gt $SourceText.Length) {
            continue
        }
        $gap = $SourceText.Substring($gapStart, $gapLength)
        if ($gap -notmatch '^[\s;]*$') {
            continue
        }

        $normalizedLocation = ([string]$paths[0]).Trim()
        if ($normalizedLocation -match '^(?i:variable):[\\/]?$') {
            return $true
        }
        return $false
    }
    return $false
}

function Test-BraintrustRelativeCurrentVariableProviderPathTargetsAutomaticVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathText,

        [Parameter(Mandatory = $true)]
        [bool]$LiteralPath
    )

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return $false
    }
    # Only model a simple provider-relative name/pattern. Scoped names, rooted
    # provider paths, dot segments and dynamic path composition remain unmodeled.
    if ($PathText.Contains(':') -or $PathText.Contains([char]92) -or $PathText.Contains([char]47)) {
        return $false
    }
    return Test-BraintrustVariableProviderPathTargetsAutomaticVariable -PathText ('Variable:' + $PathText) -LiteralPath $LiteralPath
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
    $functionDefinitionAsts = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true))

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
        foreach ($writeTarget in (Get-BraintrustVariableNameWriteTargets -CommandAst $commandAst -FunctionDefinitionAsts $functionDefinitionAsts)) {
            $targetAst = $writeTarget.TargetAst
            $writeKind = [string]$writeTarget.Kind
            foreach ($literalName in (Get-BraintrustStaticStringValues -ValueAst $targetAst)) {
                $isAutomaticVariableName = Test-BraintrustAutomaticVariableNameText -Name $literalName
                $isKnownAllVariablesPattern = (($writeKind -eq 'clear-variable' -or $writeKind -eq 'remove-variable') -and ([string]$literalName -eq '*'))
                if ($isAutomaticVariableName -or $isKnownAllVariablesPattern) {
                    $collisions += [pscustomobject]@{
                        Kind = $(if ($isKnownAllVariablesPattern) { $writeKind + '-all-variables-pattern' } else { $writeKind })
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

        $immediatelyInVariableProviderLocation = Test-BraintrustImmediatelyInVariableProviderLocation -CommandAst $commandAst -CommandAsts @($commandAsts) -SourceText $sourceText
        foreach ($providerTarget in (Get-BraintrustProviderItemMutationTargets -CommandAst $commandAst -FunctionDefinitionAsts $functionDefinitionAsts)) {
            $targetAst = $providerTarget.TargetAst
            $writeKind = [string]$providerTarget.Kind
            $isLiteralPath = [bool]$providerTarget.LiteralPath

            foreach ($literalPath in (Get-BraintrustStaticStringValues -ValueAst $targetAst)) {
                $explicitProviderCollision = Test-BraintrustVariableProviderPathTargetsAutomaticVariable -PathText ([string]$literalPath) -LiteralPath $isLiteralPath
                $currentLocationCollision = (-not $explicitProviderCollision -and $immediatelyInVariableProviderLocation -and
                    (Test-BraintrustRelativeCurrentVariableProviderPathTargetsAutomaticVariable -PathText ([string]$literalPath) -LiteralPath $isLiteralPath))
                if ($explicitProviderCollision -or $currentLocationCollision) {
                    $collisions += [pscustomobject]@{
                        Kind = $(if ($currentLocationCollision) { $writeKind + '-current-location' } else { $writeKind })
                        Variable = [string]$literalPath
                        Extent = $targetAst.Extent
                    }
                }
            }

            if ($targetAst -is [System.Management.Automation.Language.VariableExpressionAst]) {
                foreach ($literalPath in (Get-BraintrustAdjacentStaticStringValuesForVariableTarget -VariableAst $targetAst -CommandAst $commandAst -AssignmentAsts @($assignmentAsts) -SourceText $sourceText)) {
                    $explicitProviderCollision = Test-BraintrustVariableProviderPathTargetsAutomaticVariable -PathText ([string]$literalPath) -LiteralPath $isLiteralPath
                    $currentLocationCollision = (-not $explicitProviderCollision -and $immediatelyInVariableProviderLocation -and
                        (Test-BraintrustRelativeCurrentVariableProviderPathTargetsAutomaticVariable -PathText ([string]$literalPath) -LiteralPath $isLiteralPath))
                    if ($explicitProviderCollision -or $currentLocationCollision) {
                        $suffix = if ($currentLocationCollision) { '-current-location-adjacent-constant' } else { '-adjacent-constant' }
                        $collisions += [pscustomobject]@{
                            Kind = ($writeKind + $suffix)
                            Variable = [string]$literalPath
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