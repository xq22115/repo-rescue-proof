Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$shellPath = $currentProcess.MainModule.FileName
if ([string]::IsNullOrWhiteSpace($shellPath) -or -not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
    throw 'Could not resolve current PowerShell executable.'
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("braintrust-provider-location-{0}" -f [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tempRoot -Force)

function Invoke-ChildCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][int]$ExpectedExitCode,
        [bool]$ExpectMarker = $false
    )
    $path = Join-Path $tempRoot ($Name + '.ps1')
    Set-Content -LiteralPath $path -Value $Script -Encoding UTF8
    $stdoutPath = Join-Path $tempRoot ($Name + '.stdout.txt')
    $stderrPath = Join-Path $tempRoot ($Name + '.stderr.txt')
    $process = Start-Process -FilePath $shellPath -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$path) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $stdout = if (Test-Path -LiteralPath $stdoutPath) { [System.IO.File]::ReadAllText($stdoutPath) } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
    $output = $stdout + $stderr
    $exitCode = [int]$process.ExitCode
    if ($exitCode -ne $ExpectedExitCode) {
        throw "Case '$Name' expected exit $ExpectedExitCode but saw $exitCode. Output: $output"
    }
    $markerSeen = $output.Contains('BRAINTRUST_MUTATION_COMPLETED')
    if ($ExpectMarker -and -not $markerSeen) { throw "Case '$Name' expected completion marker. Output: $output" }
    if (-not $ExpectMarker -and $markerSeen) { throw "Case '$Name' unexpectedly completed protected mutation. Output: $output" }
}

$expectedAliases = [ordered]@{
    cd = 'Set-Location'
    chdir = 'Set-Location'
    sl = 'Set-Location'
    pushd = 'Push-Location'
    popd = 'Pop-Location'
}
foreach ($aliasName in $expectedAliases.Keys) {
    $alias = Get-Alias -Name $aliasName -ErrorAction Stop
    if ([string]$alias.Definition -ine [string]$expectedAliases[$aliasName]) {
        throw "Alias '$aliasName' expected '$($expectedAliases[$aliasName])' but resolved '$($alias.Definition)'."
    }
}

$ordinaryName = 'BraintrustCurrentLocationOrdinary'
$locationCommands = @('Set-Location','cd','chdir','sl','Push-Location','pushd')
try {
    foreach ($locationCommand in $locationCommands) {
        $caseName = ($locationCommand -replace '[^A-Za-z0-9]','').ToLowerInvariant()
        Invoke-ChildCase -Name ($caseName + '-ordinary-set-item') -ExpectedExitCode 0 -ExpectMarker $true -Script @"
`$ErrorActionPreference = 'Stop'
Set-Variable -Name '$ordinaryName' -Value 'before'
$locationCommand Variable:
if ((Get-Location).Provider.Name -ine 'Variable') { throw 'location command did not enter Variable provider' }
Set-Item -LiteralPath '$ordinaryName' -Value 'after'
if ((Get-Variable -Name '$ordinaryName' -ValueOnly) -ne 'after') { throw 'ordinary relative Set-Item failed' }
Write-Output 'BRAINTRUST_MUTATION_COMPLETED'
"@

        foreach ($command in @('Set-Item','Clear-Item','Remove-Item')) {
            $mutationArgs = if ($command -eq 'Set-Item') { "-LiteralPath 'PID' -Value 1 -Force" } else { "-LiteralPath 'PID' -Force" }
            Invoke-ChildCase -Name ($caseName + '-' + $command.ToLowerInvariant() + '-pid') -ExpectedExitCode 1 -ExpectMarker $false -Script @"
`$ErrorActionPreference = 'Stop'
$locationCommand Variable:
if ((Get-Location).Provider.Name -ine 'Variable') { throw 'location command did not enter Variable provider' }
$command $mutationArgs
Write-Output 'BRAINTRUST_MUTATION_COMPLETED'
"@
        }
    }

    foreach ($pushPopPair in @(
        [pscustomobject]@{ Push = 'Push-Location'; Pop = 'Pop-Location'; Name = 'cmdlet' },
        [pscustomobject]@{ Push = 'pushd'; Pop = 'popd'; Name = 'alias' }
    )) {
        Invoke-ChildCase -Name ('push-pop-restore-' + $pushPopPair.Name) -ExpectedExitCode 0 -ExpectMarker $true -Script @"
`$ErrorActionPreference = 'Stop'
`$before = (Get-Location).Provider.Name
$($pushPopPair.Push) Variable:
if ((Get-Location).Provider.Name -ine 'Variable') { throw 'push command did not enter Variable provider' }
$($pushPopPair.Pop)
if ((Get-Location).Provider.Name -ine `$before) { throw 'pop command did not restore prior provider' }
Write-Output 'BRAINTRUST_MUTATION_COMPLETED'
"@
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host 'PowerShell Variable: current-location alias/push-pop native canary PASS.' -ForegroundColor Green
