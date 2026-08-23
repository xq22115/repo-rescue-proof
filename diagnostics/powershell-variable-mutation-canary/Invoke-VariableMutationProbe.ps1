param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$RunnerImage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$shellPath = $currentProcess.MainModule.FileName
if ([string]::IsNullOrWhiteSpace($shellPath) -or -not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
    throw 'Could not resolve current PowerShell executable.'
}

$probes = @(
    [pscustomobject]@{ Name = 'clear-variable-pid'; Command = "Clear-Variable -Name PID -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'clear-variable-error'; Command = "Clear-Variable -Name Error -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'clear-variable-wildcard-all'; Command = "Clear-Variable -Name '*' -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'remove-variable-pid'; Command = "Remove-Variable -Name PID -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },

    # Explicit Variable: provider paths are a separate mutation surface from the
    # *-Variable cmdlets above. Keep each destructive probe in its own child shell.
    [pscustomobject]@{ Name = 'set-item-variable-pid-literal'; Command = "Set-Item -LiteralPath 'Variable:PID' -Value 1 -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'set-item-variable-pid-path'; Command = "Set-Item -Path 'Variable:PID' -Value 1 -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'clear-item-variable-pid-literal'; Command = "Clear-Item -LiteralPath 'Variable:PID' -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'remove-item-variable-pid-literal'; Command = "Remove-Item -LiteralPath 'Variable:PID' -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'set-item-variable-error-literal'; Command = "Set-Item -LiteralPath 'Variable:Error' -Value @() -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'set-item-variable-backslash-pid'; Command = "Set-Item -LiteralPath 'Variable:\PID' -Value 1 -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'set-item-variable-global-pid'; Command = "Set-Item -LiteralPath 'Variable:global:PID' -Value 1 -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'set-item-relative-after-variable-location'; Command = "Set-Location Variable:; Set-Item -LiteralPath 'PID' -Value 1 -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'clear-item-variable-p-wildcard'; Command = "Clear-Item -Path 'Variable:P*' -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },

    # Built-in aliases are relevant to a static guard because the command name can
    # be short while the provider-qualified target remains fully explicit.
    [pscustomobject]@{ Name = 'si-variable-pid'; Command = "si -LiteralPath 'Variable:PID' -Value 1 -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'cli-variable-pid'; Command = "cli -LiteralPath 'Variable:PID' -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'ri-variable-pid'; Command = "ri -LiteralPath 'Variable:PID' -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },

    # Positive controls prove ordinary Variable: provider operations really work in
    # the same shell/runtime, so a failure above is not simply "provider unavailable".
    [pscustomobject]@{ Name = 'ordinary-set-item-provider-path'; Command = '$n="BraintrustProviderSetProbe"; Set-Variable -Name $n -Value "before"; Set-Item -LiteralPath ("Variable:" + $n) -Value "after" -ErrorAction Stop; if ((Get-Variable -Name $n -ValueOnly) -ne "after") { throw "SET_PROVIDER_POSITIVE_CONTROL_FAILED" }; "PROBE_COMPLETED"' },
    [pscustomobject]@{ Name = 'ordinary-clear-item-provider-path'; Command = '$n="BraintrustProviderClearProbe"; Set-Variable -Name $n -Value "before"; Clear-Item -LiteralPath ("Variable:" + $n) -ErrorAction Stop; $v=Get-Variable -Name $n -ErrorAction Stop; if ($null -ne $v.Value) { throw "CLEAR_PROVIDER_POSITIVE_CONTROL_FAILED" }; "PROBE_COMPLETED"' },
    [pscustomobject]@{ Name = 'ordinary-remove-item-provider-path'; Command = '$n="BraintrustProviderRemoveProbe"; Set-Variable -Name $n -Value "before"; Remove-Item -LiteralPath ("Variable:" + $n) -ErrorAction Stop; if ($null -ne (Get-Variable -Name $n -ErrorAction SilentlyContinue)) { throw "REMOVE_PROVIDER_POSITIVE_CONTROL_FAILED" }; "PROBE_COMPLETED"' }
)

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("braintrust-variable-mutation-probe-{0}" -f [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tempRoot -Force)

try {
    $results = @()
    foreach ($probe in $probes) {
        $stdoutPath = Join-Path $tempRoot ($probe.Name + '.stdout.txt')
        $stderrPath = Join-Path $tempRoot ($probe.Name + '.stderr.txt')
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$probe.Command))
        $process = Start-Process -FilePath $shellPath -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
        ) -PassThru -Wait -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { [IO.File]::ReadAllText($stdoutPath) } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [IO.File]::ReadAllText($stderrPath) } else { '' }
        $stdoutBytes = [Text.Encoding]::UTF8.GetBytes($stdout)
        $stderrBytes = [Text.Encoding]::UTF8.GetBytes($stderr)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $stdoutSha = ([BitConverter]::ToString($sha.ComputeHash($stdoutBytes))).Replace('-', '').ToLowerInvariant()
            $stderrSha = ([BitConverter]::ToString($sha.ComputeHash($stderrBytes))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }

        $results += [ordered]@{
            name = $probe.Name
            exitCode = [int]$process.ExitCode
            completedMarkerObserved = ($stdout -match 'PROBE_COMPLETED')
            stdoutByteCount = [int]$stdoutBytes.Length
            stderrByteCount = [int]$stderrBytes.Length
            stdoutSha256 = $stdoutSha
            stderrSha256 = $stderrSha
        }
    }

    $receipt = [ordered]@{
        component = 'public-powershell-automatic-variable-mutation-canary'
        schemaVersion = 2
        diagnosticOnly = $true
        runner = [ordered]@{
            image = $RunnerImage
            runnerOs = $env:RUNNER_OS
            runnerArch = $env:RUNNER_ARCH
            osVersion = [Environment]::OSVersion.VersionString
        }
        shell = [ordered]@{
            path = $shellPath
            edition = $PSVersionTable.PSEdition
            version = $PSVersionTable.PSVersion.ToString()
        }
        probes = $results
        acceptanceBoundary = [ordered]@{
            privateBraintrustCodeIncluded = $false
            automaticVariableMutationBehaviorObserved = $true
            variableProviderMutationBehaviorObserved = $true
            canonicalBraintrustGuardModified = $false
            privateBraintrustPortableWindowsContractAccepted = $false
            targetWindowsOdrAccepted = $false
            mcpSemanticToolAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }

    $parent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [IO.File]::WriteAllText($OutputPath, (($receipt | ConvertTo-Json -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
