param(
    [Parameter(Mandatory = $true)][string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

if ($env:OS -ne 'Windows_NT') { throw 'Native spawned-process identity canary requires Windows.' }
if ([string]$PSVersionTable.PSEdition -ne 'Core' -or [int]$PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Native spawned-process identity canary requires PowerShell 7+.'
}

$helper = Join-Path $PSScriptRoot 'Get-Windows-Mcp-SpawnedProcessIdentityEvidence.ps1'
Assert-True (Test-Path -LiteralPath $helper -PathType Leaf) 'Identity helper is missing.'

$current = Get-Process -Id $PID -ErrorAction Stop
$pwshPath = [System.IO.Path]::GetFullPath([string]$current.Path)
$pwshSha = (Get-FileHash -LiteralPath $pwshPath -Algorithm SHA256).Hash.ToLowerInvariant()
$child = $null
$tempDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($ReceiptPath))
if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshPath
    $psi.ArgumentList.Add('-NoLogo')
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-NonInteractive')
    $psi.ArgumentList.Add('-Command')
    $psi.ArgumentList.Add('Start-Sleep -Seconds 30')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $spawnStart = [datetimeoffset]::UtcNow
    $child = [System.Diagnostics.Process]::new()
    $child.StartInfo = $psi
    Assert-True ($child.Start()) 'Failed to start child PowerShell process.'
    $child.Refresh()
    $spawnEnd = [datetimeoffset]::UtcNow

    $positivePath = [System.IO.Path]::GetFullPath($ReceiptPath)
    $positive = & $helper `
        -ProcessId $child.Id `
        -ExpectedExecutablePath $pwshPath `
        -ExpectedExecutableSha256 $pwshSha `
        -SpawnWindowStartUtc $spawnStart.ToString('o') `
        -SpawnWindowEndUtc $spawnEnd.ToString('o') `
        -AllowedClockSkewSeconds 5 `
        -ReceiptPath $positivePath

    Assert-True ([bool]$positive.spawnedProcessIdentityAccepted) 'Positive child process identity was not accepted.'
    $saved = Get-Content -LiteralPath $positivePath -Raw | ConvertFrom-Json
    Assert-True ([string]$saved.component -eq 'windows-mcp-spawned-process-identity-evidence') 'Positive receipt component changed.'
    Assert-True ([int]$saved.schemaVersion -eq 1) 'Positive receipt schema changed.'
    Assert-True ([int]$saved.observedProcess.pid -eq $child.Id) 'Positive receipt PID mismatch.'
    Assert-True ([bool]$saved.acceptanceBoundary.spawnedProcessIdentityAccepted) 'Positive receipt lost identity acceptance.'
    Assert-True ([bool]$saved.acceptanceBoundary.processStartTimeBoundToSpawnWindow) 'Positive receipt lost spawn-window binding.'
    Assert-True (-not [bool]$saved.acceptanceBoundary.processLifetimeRaceFree) 'Positive receipt overclaimed race-free process lifetime.'
    Assert-True (-not [bool]$saved.acceptanceBoundary.exactLoadedImageBytesCryptographicallyProven) 'Positive receipt overclaimed mapped-image attestation.'
    Assert-True (-not [bool]$saved.acceptanceBoundary.downstreamMcpServerPhysicalIdentityAccepted) 'Positive receipt overclaimed downstream MCP server identity.'

    $wrongSha = ('0' * 64)
    if ($wrongSha -eq $pwshSha) { $wrongSha = ('1' * 64) }
    Assert-Throws {
        & $helper `
            -ProcessId $child.Id `
            -ExpectedExecutablePath $pwshPath `
            -ExpectedExecutableSha256 $wrongSha `
            -SpawnWindowStartUtc $spawnStart.ToString('o') `
            -SpawnWindowEndUtc $spawnEnd.ToString('o') `
            -ReceiptPath (Join-Path $tempDir 'wrong-sha.json') | Out-Null
    } 'Identity helper accepted a wrong expected executable hash.'

    $futureStart = [datetimeoffset]::UtcNow.AddMinutes(5)
    $futureEnd = $futureStart.AddSeconds(1)
    Assert-Throws {
        & $helper `
            -ProcessId $child.Id `
            -ExpectedExecutablePath $pwshPath `
            -ExpectedExecutableSha256 $pwshSha `
            -SpawnWindowStartUtc $futureStart.ToString('o') `
            -SpawnWindowEndUtc $futureEnd.ToString('o') `
            -AllowedClockSkewSeconds 0 `
            -ReceiptPath (Join-Path $tempDir 'wrong-window.json') | Out-Null
    } 'Identity helper accepted a process lifetime outside the supplied spawn window.'

    $canary = [ordered]@{
        schemaVersion = 1
        component = 'public-windows-spawned-process-identity-canary'
        generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        osVersion = [System.Environment]::OSVersion.VersionString
        powershellEdition = [string]$PSVersionTable.PSEdition
        powershellVersion = [string]$PSVersionTable.PSVersion
        architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        child = [ordered]@{
            executablePath = $pwshPath
            executableSha256 = $pwshSha
            pid = $child.Id
            spawnWindowStartUtc = $spawnStart.ToString('o')
            spawnWindowEndUtc = $spawnEnd.ToString('o')
            identityReceiptSha256 = [string]$positive.receiptSha256
        }
        negativeCases = [ordered]@{
            wrongExecutableHashRejected = $true
            impossibleFutureSpawnWindowRejected = $true
        }
        acceptanceBoundary = [ordered]@{
            nativeWindowsProcessImagePathAndBackingHashObserved = $true
            processStartTimeBoundToSpawnWindow = $true
            exactLoadedImageBytesCryptographicallyProven = $false
            productionOdrIntegrationAccepted = $false
            downstreamMcpServerPhysicalIdentityAccepted = $false
            semanticToolAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }
    $canaryPath = Join-Path $tempDir 'spawned-process-canary-summary.json'
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($canaryPath, ($canary | ConvertTo-Json -Depth 8), $utf8NoBom)
    Write-Host "SPAWNED_PROCESS_IDENTITY_CANARY_PASS receipt=$positivePath summary=$canaryPath"
} finally {
    if ($null -ne $child) {
        try { if (-not $child.HasExited) { $child.Kill($true) } } catch { try { $child.Kill() } catch {} }
        try { [void]$child.WaitForExit(5000) } catch {}
        $child.Dispose()
    }
}
