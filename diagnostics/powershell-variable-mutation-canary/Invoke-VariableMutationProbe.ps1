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
    [pscustomobject]@{ Name = 'set-item-variable-pid'; Command = "Set-Item -LiteralPath 'Variable:PID' -Value 1 -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'clear-item-variable-pid'; Command = "Clear-Item -LiteralPath 'Variable:PID' -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'remove-item-variable-pid'; Command = "Remove-Item -LiteralPath 'Variable:PID' -Force -ErrorAction Stop; 'PROBE_COMPLETED'" },
    [pscustomobject]@{ Name = 'set-item-variable-error'; Command = "Set-Item -LiteralPath 'Variable:Error' -Value @() -Force -ErrorAction Stop; 'PROBE_COMPLETED'" }
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
        schemaVersion = 1
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
