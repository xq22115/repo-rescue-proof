Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-ExpectVeto([scriptblock]$Action, [string]$Label) {
    $vetoed = $false
    try { & $Action } catch { $vetoed = $true }
    Assert-True $vetoed "$Label did not fail closed."
}

if ($env:OS -ne 'Windows_NT') { throw 'Native Windows is required.' }

$root = Join-Path $env:RUNNER_TEMP ('braintrust-prewire-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    $currentExe = [System.IO.Path]::GetFullPath([string](Get-Process -Id $PID).Path)
    $currentExeSha = (Get-FileHash -LiteralPath $currentExe -Algorithm SHA256).Hash.ToLowerInvariant()
    $commandText = 'Start-Sleep -Seconds 45'
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandText))

    $spawnStart = [datetimeoffset]::UtcNow
    $child = Start-Process -FilePath $currentExe -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encodedCommand) -PassThru
    $spawnEnd = [datetimeoffset]::UtcNow
    try {
        Start-Sleep -Milliseconds 250
        $spawnReceipt = Join-Path $root 'spawn.json'
        $spawn = & (Join-Path $PSScriptRoot 'Get-Windows-Mcp-SpawnedProcessIdentityEvidence.ps1') `
            -ProcessId $child.Id `
            -ExpectedExecutablePath $currentExe `
            -ExpectedExecutableSha256 $currentExeSha `
            -SpawnWindowStartUtc $spawnStart.ToString('o') `
            -SpawnWindowEndUtc $spawnEnd.ToString('o') `
            -ReceiptPath $spawnReceipt
        Assert-True ([bool]$spawn.spawnedProcessIdentityAccepted) 'Spawn identity helper did not accept the fresh child.'

        $preWireReceipt = Join-Path $root 'prewire.json'
        $preWire = & (Join-Path $PSScriptRoot 'Get-Windows-Mcp-PreWireProcessIdentityRevalidation.ps1') `
            -SpawnedProcessIdentityReceiptPath $spawnReceipt `
            -ExpectedSpawnedProcessIdentityReceiptSha256 $spawn.receiptSha256 `
            -ReceiptPath $preWireReceipt
        Assert-True ([bool]$preWire.preWireProcessIdentityRevalidationAccepted) 'Pre-wire helper did not accept the same live process lifetime.'
        Assert-True ($preWire.processId -eq $child.Id) 'Pre-wire helper returned a different PID.'
        Assert-True (-not [bool]$preWire.processLifetimeRaceFree) 'Pre-wire helper must not claim race-free process lifetime.'
        Assert-True (-not [bool]$preWire.downstreamMcpServerPhysicalIdentityAccepted) 'Pre-wire helper must not promote downstream MCP server identity.'

        $tamperedReceipt = Join-Path $root 'tampered-start.json'
        $tampered = (Get-Content -LiteralPath $spawnReceipt -Raw) | ConvertFrom-Json
        $tampered.observedProcess.startTimeUtc = '2000-01-01T00:00:00.0000000+00:00'
        [System.IO.File]::WriteAllText($tamperedReceipt, ($tampered | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
        $tamperedSha = (Get-FileHash -LiteralPath $tamperedReceipt -Algorithm SHA256).Hash.ToLowerInvariant()
        Invoke-ExpectVeto -Label 'tampered StartTime' -Action {
            & (Join-Path $PSScriptRoot 'Get-Windows-Mcp-PreWireProcessIdentityRevalidation.ps1') `
                -SpawnedProcessIdentityReceiptPath $tamperedReceipt `
                -ExpectedSpawnedProcessIdentityReceiptSha256 $tamperedSha `
                -ReceiptPath (Join-Path $root 'tampered-output.json') | Out-Null
        }

        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $child.Id -ErrorAction SilentlyContinue
        Invoke-ExpectVeto -Label 'exited process' -Action {
            & (Join-Path $PSScriptRoot 'Get-Windows-Mcp-PreWireProcessIdentityRevalidation.ps1') `
                -SpawnedProcessIdentityReceiptPath $spawnReceipt `
                -ExpectedSpawnedProcessIdentityReceiptSha256 $spawn.receiptSha256 `
                -ReceiptPath (Join-Path $root 'exited-output.json') | Out-Null
        }

        [pscustomobject][ordered]@{
            schemaVersion = 1
            component = 'windows-mcp-pre-wire-process-identity-native-canary'
            osVersion = [Environment]::OSVersion.VersionString
            powershellEdition = [string]$PSVersionTable.PSEdition
            powershellVersion = [string]$PSVersionTable.PSVersion
            architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
            spawnedProcessIdentityAccepted = $true
            preWireProcessIdentityRevalidationAccepted = $true
            tamperedStartTimeVetoed = $true
            exitedProcessVetoed = $true
            processLifetimeRaceFree = $false
            downstreamMcpServerPhysicalIdentityAccepted = $false
            semanticToolAccepted = $false
            windowsFinalStateAccepted = $false
        } | ConvertTo-Json -Depth 6
    } finally {
        if ($null -ne $child -and -not $child.HasExited) {
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        }
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
