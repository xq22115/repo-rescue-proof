param(
    [Parameter(Mandatory = $true)]
    [string]$HelperPath,

    [Parameter(Mandatory = $true)]
    [string]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8Json([object]$Value, [string]$Path) {
    $json = $Value | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($Path), $json, (New-Object System.Text.UTF8Encoding($false)))
}

Assert-True ($env:OS -eq 'Windows_NT') 'Native Windows is required.'
Assert-True ([string]$PSVersionTable.PSEdition -eq 'Core') 'This canary must run under PowerShell Core.'
Assert-True ([int]$PSVersionTable.PSVersion.Major -ge 7) 'This canary requires PowerShell 7 or later.'
Assert-True (Test-Path -LiteralPath $HelperPath -PathType Leaf) 'Host-binding helper was not found.'

$tempRoot = Join-Path $env:RUNNER_TEMP ('broker-host-binding-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    $currentExe = [System.IO.Path]::GetFullPath([string]$currentProcess.MainModule.FileName)
    $currentSha = Get-FileSha256 $currentExe
    $currentVersion = [string]$PSVersionTable.PSVersion
    $currentFramework = [string][System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
    $architecture = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) { 'Arm64' } else { 'X64' }
    $platformKey = if ($architecture -eq 'Arm64') { 'windows-arm64' } else { 'windows-amd64' }

    $brokerReceiptPath = Join-Path $tempRoot 'broker-receipt.json'
    $brokerReceipt = [ordered]@{
        schemaVersion = 1
        component = 'windows-mcp-powershell-transport-broker-install'
        sourceRelease = [ordered]@{
            repository = 'PowerShell/PowerShell'
            tag = ('v' + $currentVersion)
        }
        installedBroker = [ordered]@{
            executablePath = $currentExe
            executableSha256 = $currentSha
            powershellEdition = 'Core'
            powershellVersion = $currentVersion
            frameworkDescription = $currentFramework
            platformKey = $platformKey
            standardInputEncodingPropertyObserved = $true
        }
        acceptanceBoundary = [ordered]@{
            officialReleaseTagAccepted = $true
            installedExecutableExactSha256Observed = $true
            powershellCoreExactVersionAccepted = $true
            modernDotnetStandardInputEncodingAvailable = $true
            pathMutationPerformed = $false
            automaticUpdateEnabledByInstaller = $false
            productionOdrBrokerIntegrationAccepted = $false
            semanticMcpFunctionalityAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }
    Write-Utf8Json -Value $brokerReceipt -Path $brokerReceiptPath
    $brokerReceiptSha = Get-FileSha256 $brokerReceiptPath

    $installReceiptPath = Join-Path $tempRoot 'install-receipt.json'
    $installReceipt = [ordered]@{
        schemaVersion = 3
        component = 'openai-tunnel-client'
        architecture = $architecture
        powershellTransportBroker = [ordered]@{
            receiptPath = $brokerReceiptPath
            receiptSha256 = $brokerReceiptSha
            component = 'windows-mcp-powershell-transport-broker-install'
            repository = 'PowerShell/PowerShell'
            releaseTag = ('v' + $currentVersion)
            platformKey = $platformKey
            executablePath = $currentExe
            executableSha256 = $currentSha
            powershellEdition = 'Core'
            powershellVersion = $currentVersion
            frameworkDescription = $currentFramework
            standardInputEncodingPropertyObserved = $true
            pathMutationPerformed = $false
            automaticUpdateEnabledByInstaller = $false
            productionOdrBrokerIntegrationAccepted = $false
            semanticMcpFunctionalityAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }
    Write-Utf8Json -Value $installReceipt -Path $installReceiptPath
    $installReceiptSha = Get-FileSha256 $installReceiptPath

    $hostReceiptPath = Join-Path $tempRoot 'host-binding-receipt.json'
    $result = & $HelperPath -InstallReceiptPath $installReceiptPath -InstallReceiptSha256 $installReceiptSha -ReceiptPath $hostReceiptPath
    Assert-True ([bool]$result.transportBrokerHostBindingAccepted) 'Happy-path broker host binding was not accepted.'
    $hostReceipt = (Get-Content -LiteralPath $hostReceiptPath -Raw) | ConvertFrom-Json
    Assert-True ([bool]$hostReceipt.acceptanceBoundary.currentHostProcessExactBrokerExecutableAccepted) 'Current host exact executable binding was not accepted.'
    Assert-True (-not [bool]$hostReceipt.acceptanceBoundary.pathLookupUsed) 'Host binding must not use PATH lookup.'
    Assert-True (-not [bool]$hostReceipt.acceptanceBoundary.ambientPowerShellAccepted) 'Host binding must not accept ambient PowerShell.'
    Assert-True (-not [bool]$hostReceipt.acceptanceBoundary.productionOdrConsumerAccepted) 'Diagnostic host binding must not pre-claim production ODR consumption.'

    # Same bytes at a different path must not be accepted as the current transport-broker host.
    $copiedExe = Join-Path $tempRoot 'copied-pwsh.exe'
    Copy-Item -LiteralPath $currentExe -Destination $copiedExe -Force
    Assert-True ((Get-FileSha256 $copiedExe) -eq $currentSha) 'Copied pwsh.exe bytes differ unexpectedly.'
    $brokerReceipt.installedBroker.executablePath = $copiedExe
    Write-Utf8Json -Value $brokerReceipt -Path $brokerReceiptPath
    $brokerReceiptSha2 = Get-FileSha256 $brokerReceiptPath
    $installReceipt.powershellTransportBroker.receiptSha256 = $brokerReceiptSha2
    $installReceipt.powershellTransportBroker.executablePath = $copiedExe
    Write-Utf8Json -Value $installReceipt -Path $installReceiptPath
    $installReceiptSha2 = Get-FileSha256 $installReceiptPath
    $wrongPathRejected = $false
    try {
        & $HelperPath -InstallReceiptPath $installReceiptPath -InstallReceiptSha256 $installReceiptSha2 -ReceiptPath (Join-Path $tempRoot 'wrong-path.json') | Out-Null
    } catch {
        $wrongPathRejected = ([string]$_.Exception.Message -match 'not the exact receipt-bound transport-broker executable')
    }
    Assert-True $wrongPathRejected 'Same-byte broker at a different path was not rejected.'

    $evidence = [ordered]@{
        schemaVersion = 1
        component = 'public-windows-powershell-transport-broker-host-binding-canary'
        observedAtUtc = [datetime]::UtcNow.ToString('o')
        runner = [ordered]@{
            os = [string]$env:RUNNER_OS
            architecture = [string]$env:RUNNER_ARCH
            image = [string]$env:ImageOS
            imageVersion = [string]$env:ImageVersion
        }
        currentHost = [ordered]@{
            executablePath = $currentExe
            executableSha256 = $currentSha
            processId = [int]$currentProcess.Id
            processStartTimeUtc = $currentProcess.StartTime.ToUniversalTime().ToString('o')
            powershellEdition = [string]$PSVersionTable.PSEdition
            powershellVersion = $currentVersion
            frameworkDescription = $currentFramework
        }
        checks = [ordered]@{
            syntheticMainInstallReceiptAccepted = $true
            exactCurrentHostPathAndShaAccepted = $true
            sameBytesDifferentPathRejected = $wrongPathRejected
            processStartTimeObserved = $true
            standardInputEncodingPropertyObserved = ($null -ne [System.Diagnostics.ProcessStartInfo].GetProperty('StandardInputEncoding'))
        }
        acceptanceBoundary = [ordered]@{
            publicNativeHostBindingPrimitiveAccepted = $true
            privateBraintrustInstallReceiptUsed = $false
            privateBraintrustBrokerInstallReceiptUsed = $false
            productionOdrConsumerAccepted = $false
            mappedImageCryptographicallyProven = $false
            downstreamMcpServerPhysicalIdentityAccepted = $false
            mcpProtocolRuntimeAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }
    Write-Utf8Json -Value $evidence -Path $EvidencePath
    Write-Host 'PowerShell transport-broker current-host binding canary: PASS'
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
