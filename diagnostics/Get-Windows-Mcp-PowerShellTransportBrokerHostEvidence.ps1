param(
    [Parameter(Mandatory = $true)]
    [string]$InstallReceiptPath,

    [Parameter(Mandatory = $true)]
    [string]$InstallReceiptSha256,

    [Parameter(Mandatory = $true)]
    [string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Sha256([string]$Value, [string]$FieldPath) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($Value)) "$FieldPath is required."
    Assert-True ($Value -match '^[0-9A-Fa-f]{64}$') "$FieldPath must be a 64-hex SHA-256 string."
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$FieldPath) {
    Assert-True ($null -ne $Object) "$FieldPath parent object is required."
    $property = $Object.PSObject.Properties[$Name]
    Assert-True ($null -ne $property) "$FieldPath is required."
    return $property.Value
}

function Get-RequiredString([object]$Object, [string]$Name, [string]$FieldPath) {
    $value = Get-RequiredProperty -Object $Object -Name $Name -FieldPath $FieldPath
    Assert-True ($value -is [string]) "$FieldPath must be a JSON string."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$value)) "$FieldPath must not be empty."
    return [string]$value
}

function Get-RequiredInteger([object]$Object, [string]$Name, [string]$FieldPath) {
    $value = Get-RequiredProperty -Object $Object -Name $Name -FieldPath $FieldPath
    Assert-True (($value -is [int]) -or ($value -is [long])) "$FieldPath must be a JSON integer."
    return [long]$value
}

function Get-RequiredBoolean([object]$Object, [string]$Name, [string]$FieldPath) {
    $value = Get-RequiredProperty -Object $Object -Name $Name -FieldPath $FieldPath
    Assert-True ($value -is [bool]) "$FieldPath must be a JSON boolean."
    return [bool]$value
}

function Get-RequiredObject([object]$Object, [string]$Name, [string]$FieldPath) {
    $value = Get-RequiredProperty -Object $Object -Name $Name -FieldPath $FieldPath
    Assert-True ($null -ne $value -and -not ($value -is [string]) -and $null -ne $value.PSObject) "$FieldPath must be a JSON object."
    return $value
}

function Get-NormalizedPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-SamePath([string]$Actual, [string]$Expected, [string]$Message) {
    $actualFull = Get-NormalizedPath $Actual
    $expectedFull = Get-NormalizedPath $Expected
    Assert-True ($actualFull.Equals($expectedFull, [StringComparison]::OrdinalIgnoreCase)) $Message
}

Assert-True ($env:OS -eq 'Windows_NT') 'PowerShell transport-broker host evidence is Windows-only.'
Assert-True ([string]$PSVersionTable.PSEdition -eq 'Core') 'The current host must be PowerShell Core; Windows PowerShell 5.1 cannot be accepted as the MCP stdio transport broker.'
Assert-True ([int]$PSVersionTable.PSVersion.Major -ge 7) 'The current host must be PowerShell 7 or later.'
Assert-True (Test-Path -LiteralPath $InstallReceiptPath -PathType Leaf) 'Main install receipt was not found.'
Assert-Sha256 -Value $InstallReceiptSha256 -FieldPath 'InstallReceiptSha256'
$installReceiptObservedSha256 = Get-FileSha256 $InstallReceiptPath
Assert-True ($installReceiptObservedSha256 -eq $InstallReceiptSha256.ToLowerInvariant()) 'Main install receipt bytes do not match the externally supplied SHA-256.'

$installReceipt = (Get-Content -LiteralPath $InstallReceiptPath -Raw) | ConvertFrom-Json
$installSchema = Get-RequiredInteger -Object $installReceipt -Name 'schemaVersion' -FieldPath 'installReceipt.schemaVersion'
Assert-True ($installSchema -eq 3) 'Main install receipt schemaVersion must be exactly 3 for transport-broker host binding.'
$installComponent = Get-RequiredString -Object $installReceipt -Name 'component' -FieldPath 'installReceipt.component'
Assert-True ($installComponent -eq 'openai-tunnel-client') 'Main install receipt component is invalid.'
$installArchitecture = Get-RequiredString -Object $installReceipt -Name 'architecture' -FieldPath 'installReceipt.architecture'
Assert-True (@('X64', 'Arm64') -contains $installArchitecture) 'Main install receipt architecture is unsupported.'

$mainBroker = Get-RequiredObject -Object $installReceipt -Name 'powershellTransportBroker' -FieldPath 'installReceipt.powershellTransportBroker'
$mainBrokerReceiptPath = Get-RequiredString -Object $mainBroker -Name 'receiptPath' -FieldPath 'installReceipt.powershellTransportBroker.receiptPath'
$mainBrokerReceiptSha256 = Get-RequiredString -Object $mainBroker -Name 'receiptSha256' -FieldPath 'installReceipt.powershellTransportBroker.receiptSha256'
Assert-Sha256 -Value $mainBrokerReceiptSha256 -FieldPath 'installReceipt.powershellTransportBroker.receiptSha256'
$mainBrokerComponent = Get-RequiredString -Object $mainBroker -Name 'component' -FieldPath 'installReceipt.powershellTransportBroker.component'
Assert-True ($mainBrokerComponent -eq 'windows-mcp-powershell-transport-broker-install') 'Main install receipt references an unexpected transport-broker component.'
$mainBrokerRepository = Get-RequiredString -Object $mainBroker -Name 'repository' -FieldPath 'installReceipt.powershellTransportBroker.repository'
Assert-True ($mainBrokerRepository -eq 'PowerShell/PowerShell') 'Main install receipt references an unexpected PowerShell repository.'
$mainBrokerTag = Get-RequiredString -Object $mainBroker -Name 'releaseTag' -FieldPath 'installReceipt.powershellTransportBroker.releaseTag'
$mainBrokerPlatformKey = Get-RequiredString -Object $mainBroker -Name 'platformKey' -FieldPath 'installReceipt.powershellTransportBroker.platformKey'
$mainBrokerExecutablePath = Get-RequiredString -Object $mainBroker -Name 'executablePath' -FieldPath 'installReceipt.powershellTransportBroker.executablePath'
$mainBrokerExecutableSha256 = Get-RequiredString -Object $mainBroker -Name 'executableSha256' -FieldPath 'installReceipt.powershellTransportBroker.executableSha256'
Assert-Sha256 -Value $mainBrokerExecutableSha256 -FieldPath 'installReceipt.powershellTransportBroker.executableSha256'
$mainBrokerEdition = Get-RequiredString -Object $mainBroker -Name 'powershellEdition' -FieldPath 'installReceipt.powershellTransportBroker.powershellEdition'
$mainBrokerVersion = Get-RequiredString -Object $mainBroker -Name 'powershellVersion' -FieldPath 'installReceipt.powershellTransportBroker.powershellVersion'
$mainBrokerFramework = Get-RequiredString -Object $mainBroker -Name 'frameworkDescription' -FieldPath 'installReceipt.powershellTransportBroker.frameworkDescription'
$mainStandardInputEncodingObserved = Get-RequiredBoolean -Object $mainBroker -Name 'standardInputEncodingPropertyObserved' -FieldPath 'installReceipt.powershellTransportBroker.standardInputEncodingPropertyObserved'
$mainPathMutation = Get-RequiredBoolean -Object $mainBroker -Name 'pathMutationPerformed' -FieldPath 'installReceipt.powershellTransportBroker.pathMutationPerformed'
$mainAutoUpdate = Get-RequiredBoolean -Object $mainBroker -Name 'automaticUpdateEnabledByInstaller' -FieldPath 'installReceipt.powershellTransportBroker.automaticUpdateEnabledByInstaller'
$mainOdrAccepted = Get-RequiredBoolean -Object $mainBroker -Name 'productionOdrBrokerIntegrationAccepted' -FieldPath 'installReceipt.powershellTransportBroker.productionOdrBrokerIntegrationAccepted'
$mainSemanticAccepted = Get-RequiredBoolean -Object $mainBroker -Name 'semanticMcpFunctionalityAccepted' -FieldPath 'installReceipt.powershellTransportBroker.semanticMcpFunctionalityAccepted'
$mainFinalAccepted = Get-RequiredBoolean -Object $mainBroker -Name 'windowsFinalStateAccepted' -FieldPath 'installReceipt.powershellTransportBroker.windowsFinalStateAccepted'
Assert-True ($mainBrokerEdition -eq 'Core') 'Main install receipt broker edition must be Core.'
Assert-True ($mainStandardInputEncodingObserved) 'Main install receipt must prove ProcessStartInfo.StandardInputEncoding was observed for the broker.'
Assert-True (-not $mainPathMutation) 'Transport broker must not rely on PATH mutation.'
Assert-True (-not $mainAutoUpdate) 'Transport broker must not rely on installer-enabled automatic update.'
Assert-True (-not $mainOdrAccepted -and -not $mainSemanticAccepted -and -not $mainFinalAccepted) 'Main install receipt must not pre-claim ODR integration, MCP semantics, or Windows final state.'

$expectedPlatformKey = if ($installArchitecture -eq 'X64') { 'windows-amd64' } else { 'windows-arm64' }
Assert-True ($mainBrokerPlatformKey -eq $expectedPlatformKey) 'Main install receipt broker platform does not match the installed architecture.'
Assert-True ($mainBrokerTag -eq ('v' + $mainBrokerVersion)) 'Main install receipt broker release tag must exactly match the recorded PowerShell version.'
Assert-True (Test-Path -LiteralPath $mainBrokerReceiptPath -PathType Leaf) 'PowerShell transport-broker install receipt was not found.'
Assert-True ((Get-FileSha256 $mainBrokerReceiptPath) -eq $mainBrokerReceiptSha256.ToLowerInvariant()) 'PowerShell transport-broker install receipt bytes changed after the main install receipt was written.'

$brokerReceipt = (Get-Content -LiteralPath $mainBrokerReceiptPath -Raw) | ConvertFrom-Json
$brokerSchema = Get-RequiredInteger -Object $brokerReceipt -Name 'schemaVersion' -FieldPath 'brokerReceipt.schemaVersion'
Assert-True ($brokerSchema -eq 1) 'PowerShell transport-broker install receipt schemaVersion must be exactly 1.'
$brokerComponent = Get-RequiredString -Object $brokerReceipt -Name 'component' -FieldPath 'brokerReceipt.component'
Assert-True ($brokerComponent -eq $mainBrokerComponent) 'PowerShell transport-broker component differs between receipts.'
$brokerSource = Get-RequiredObject -Object $brokerReceipt -Name 'sourceRelease' -FieldPath 'brokerReceipt.sourceRelease'
$brokerRepository = Get-RequiredString -Object $brokerSource -Name 'repository' -FieldPath 'brokerReceipt.sourceRelease.repository'
$brokerTag = Get-RequiredString -Object $brokerSource -Name 'tag' -FieldPath 'brokerReceipt.sourceRelease.tag'
Assert-True ($brokerRepository -eq $mainBrokerRepository -and $brokerTag -eq $mainBrokerTag) 'PowerShell transport-broker release identity differs between receipts.'
$brokerInstalled = Get-RequiredObject -Object $brokerReceipt -Name 'installedBroker' -FieldPath 'brokerReceipt.installedBroker'
$brokerExecutablePath = Get-RequiredString -Object $brokerInstalled -Name 'executablePath' -FieldPath 'brokerReceipt.installedBroker.executablePath'
$brokerExecutableSha256 = Get-RequiredString -Object $brokerInstalled -Name 'executableSha256' -FieldPath 'brokerReceipt.installedBroker.executableSha256'
Assert-Sha256 -Value $brokerExecutableSha256 -FieldPath 'brokerReceipt.installedBroker.executableSha256'
$brokerEdition = Get-RequiredString -Object $brokerInstalled -Name 'powershellEdition' -FieldPath 'brokerReceipt.installedBroker.powershellEdition'
$brokerVersion = Get-RequiredString -Object $brokerInstalled -Name 'powershellVersion' -FieldPath 'brokerReceipt.installedBroker.powershellVersion'
$brokerFramework = Get-RequiredString -Object $brokerInstalled -Name 'frameworkDescription' -FieldPath 'brokerReceipt.installedBroker.frameworkDescription'
$brokerPlatformKey = Get-RequiredString -Object $brokerInstalled -Name 'platformKey' -FieldPath 'brokerReceipt.installedBroker.platformKey'
$brokerStandardInputEncodingObserved = Get-RequiredBoolean -Object $brokerInstalled -Name 'standardInputEncodingPropertyObserved' -FieldPath 'brokerReceipt.installedBroker.standardInputEncodingPropertyObserved'
Assert-SamePath -Actual $brokerExecutablePath -Expected $mainBrokerExecutablePath -Message 'Broker executable path differs between broker and main install receipts.'
Assert-True ($brokerExecutableSha256.ToLowerInvariant() -eq $mainBrokerExecutableSha256.ToLowerInvariant()) 'Broker executable SHA-256 differs between broker and main install receipts.'
Assert-True ($brokerEdition -eq $mainBrokerEdition -and $brokerVersion -eq $mainBrokerVersion -and $brokerFramework -eq $mainBrokerFramework -and $brokerPlatformKey -eq $mainBrokerPlatformKey -and $brokerStandardInputEncodingObserved) 'Broker runtime facts differ between broker and main install receipts.'

$brokerAcceptance = Get-RequiredObject -Object $brokerReceipt -Name 'acceptanceBoundary' -FieldPath 'brokerReceipt.acceptanceBoundary'
Assert-True (Get-RequiredBoolean -Object $brokerAcceptance -Name 'officialReleaseTagAccepted' -FieldPath 'brokerReceipt.acceptanceBoundary.officialReleaseTagAccepted') 'Broker receipt did not accept the official release tag.'
Assert-True (Get-RequiredBoolean -Object $brokerAcceptance -Name 'installedExecutableExactSha256Observed' -FieldPath 'brokerReceipt.acceptanceBoundary.installedExecutableExactSha256Observed') 'Broker receipt did not accept the installed executable SHA-256.'
Assert-True (Get-RequiredBoolean -Object $brokerAcceptance -Name 'powershellCoreExactVersionAccepted' -FieldPath 'brokerReceipt.acceptanceBoundary.powershellCoreExactVersionAccepted') 'Broker receipt did not accept the exact PowerShell Core version.'
Assert-True (Get-RequiredBoolean -Object $brokerAcceptance -Name 'modernDotnetStandardInputEncodingAvailable' -FieldPath 'brokerReceipt.acceptanceBoundary.modernDotnetStandardInputEncodingAvailable') 'Broker receipt did not accept modern .NET StandardInputEncoding support.'
Assert-True (-not (Get-RequiredBoolean -Object $brokerAcceptance -Name 'pathMutationPerformed' -FieldPath 'brokerReceipt.acceptanceBoundary.pathMutationPerformed')) 'Broker receipt must not claim PATH mutation.'
Assert-True (-not (Get-RequiredBoolean -Object $brokerAcceptance -Name 'automaticUpdateEnabledByInstaller' -FieldPath 'brokerReceipt.acceptanceBoundary.automaticUpdateEnabledByInstaller')) 'Broker receipt must not claim automatic update.'
Assert-True (-not (Get-RequiredBoolean -Object $brokerAcceptance -Name 'productionOdrBrokerIntegrationAccepted' -FieldPath 'brokerReceipt.acceptanceBoundary.productionOdrBrokerIntegrationAccepted')) 'Broker receipt must not pre-claim ODR integration.'
Assert-True (-not (Get-RequiredBoolean -Object $brokerAcceptance -Name 'semanticMcpFunctionalityAccepted' -FieldPath 'brokerReceipt.acceptanceBoundary.semanticMcpFunctionalityAccepted')) 'Broker receipt must not pre-claim MCP semantics.'
Assert-True (-not (Get-RequiredBoolean -Object $brokerAcceptance -Name 'windowsFinalStateAccepted' -FieldPath 'brokerReceipt.acceptanceBoundary.windowsFinalStateAccepted')) 'Broker receipt must not pre-claim Windows final state.'

Assert-True (Test-Path -LiteralPath $mainBrokerExecutablePath -PathType Leaf) 'Receipt-bound PowerShell broker executable no longer exists.'
$brokerExecutableObservedSha256 = Get-FileSha256 $mainBrokerExecutablePath
Assert-True ($brokerExecutableObservedSha256 -eq $mainBrokerExecutableSha256.ToLowerInvariant()) 'Receipt-bound PowerShell broker executable bytes changed after installation.'

$currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$currentProcessId = [int]$currentProcess.Id
$currentProcessStartTimeUtc = $currentProcess.StartTime.ToUniversalTime().ToString('o')
$currentMainModulePath = [string]$currentProcess.MainModule.FileName
Assert-True (-not [string]::IsNullOrWhiteSpace($currentMainModulePath)) 'Current PowerShell process image path could not be observed.'
$currentProcessPathProperty = [System.Environment].GetProperty('ProcessPath', [System.Reflection.BindingFlags]'Public,Static')
Assert-True ($null -ne $currentProcessPathProperty) 'Current PowerShell broker requires modern .NET Environment.ProcessPath.'
$currentEnvironmentProcessPath = [string]$currentProcessPathProperty.GetValue($null)
Assert-True (-not [string]::IsNullOrWhiteSpace($currentEnvironmentProcessPath)) 'Environment.ProcessPath did not return the current PowerShell executable.'
Assert-SamePath -Actual $currentMainModulePath -Expected $currentEnvironmentProcessPath -Message 'Current process MainModule and Environment.ProcessPath disagree.'
Assert-SamePath -Actual $currentMainModulePath -Expected $mainBrokerExecutablePath -Message 'Current PowerShell host is not the exact receipt-bound transport-broker executable.'
$currentExecutableSha256 = Get-FileSha256 $currentMainModulePath
Assert-True ($currentExecutableSha256 -eq $mainBrokerExecutableSha256.ToLowerInvariant()) 'Current PowerShell host executable SHA-256 differs from the receipt-bound transport broker.'

$currentEdition = [string]$PSVersionTable.PSEdition
$currentVersion = [string]$PSVersionTable.PSVersion
$currentFramework = [string][System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
Assert-True ($currentEdition -eq 'Core') 'Current transport-broker host edition is not PowerShell Core.'
Assert-True ($currentVersion -eq $mainBrokerVersion) 'Current transport-broker host version differs from the installer-owned broker version.'
Assert-True ($currentFramework -eq $mainBrokerFramework) 'Current transport-broker framework differs from the installer-owned broker framework.'
$standardInputEncodingProperty = [System.Diagnostics.ProcessStartInfo].GetProperty('StandardInputEncoding')
Assert-True ($null -ne $standardInputEncodingProperty) 'Current transport-broker runtime lacks ProcessStartInfo.StandardInputEncoding.'

# Re-read the two upstream receipts and executable after observing the live host so a stale/tampered input cannot silently survive the binding window.
Assert-True ((Get-FileSha256 $InstallReceiptPath) -eq $installReceiptObservedSha256) 'Main install receipt bytes changed during transport-broker host binding.'
Assert-True ((Get-FileSha256 $mainBrokerReceiptPath) -eq $mainBrokerReceiptSha256.ToLowerInvariant()) 'PowerShell transport-broker receipt bytes changed during host binding.'
Assert-True ((Get-FileSha256 $mainBrokerExecutablePath) -eq $mainBrokerExecutableSha256.ToLowerInvariant()) 'PowerShell transport-broker executable bytes changed during host binding.'

$receiptObject = [ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-powershell-transport-broker-host-evidence'
    capturedAtUtc = [datetime]::UtcNow.ToString('o')
    installReceipt = [ordered]@{
        path = [System.IO.Path]::GetFullPath($InstallReceiptPath)
        sha256 = $installReceiptObservedSha256
        schemaVersion = $installSchema
        architecture = $installArchitecture
    }
    brokerReceipt = [ordered]@{
        path = [System.IO.Path]::GetFullPath($mainBrokerReceiptPath)
        sha256 = $mainBrokerReceiptSha256.ToLowerInvariant()
        component = $brokerComponent
        releaseTag = $brokerTag
        platformKey = $brokerPlatformKey
    }
    expectedBroker = [ordered]@{
        executablePath = [System.IO.Path]::GetFullPath($mainBrokerExecutablePath)
        executableSha256 = $mainBrokerExecutableSha256.ToLowerInvariant()
        powershellEdition = $mainBrokerEdition
        powershellVersion = $mainBrokerVersion
        frameworkDescription = $mainBrokerFramework
        standardInputEncodingPropertyObservedAtInstall = $mainStandardInputEncodingObserved
    }
    currentHost = [ordered]@{
        processId = $currentProcessId
        processStartTimeUtc = $currentProcessStartTimeUtc
        executablePath = [System.IO.Path]::GetFullPath($currentMainModulePath)
        executableSha256 = $currentExecutableSha256
        powershellEdition = $currentEdition
        powershellVersion = $currentVersion
        frameworkDescription = $currentFramework
        standardInputEncodingPropertyObserved = $true
    }
    acceptanceBoundary = [ordered]@{
        installReceiptExactSha256Accepted = $true
        brokerReceiptExactSha256Accepted = $true
        brokerExecutableExactSha256Accepted = $true
        currentHostProcessExactBrokerExecutableAccepted = $true
        currentHostPowerShellExactVersionAccepted = $true
        currentHostModernDotnetStandardInputEncodingAccepted = $true
        pathLookupUsed = $false
        ambientPowerShellAccepted = $false
        processLifetimeRaceFree = $false
        mappedImageCryptographicallyProven = $false
        productionOdrConsumerAccepted = $false
        downstreamMcpServerPhysicalIdentityAccepted = $false
        mcpProtocolRuntimeAccepted = $false
        semanticMcpFunctionalityAccepted = $false
        windowsFinalStateAccepted = $false
    }
}

$receiptFullPath = [System.IO.Path]::GetFullPath($ReceiptPath)
$receiptDirectory = Split-Path -Parent $receiptFullPath
if (-not [string]::IsNullOrWhiteSpace($receiptDirectory)) {
    New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null
}
$receiptJson = $receiptObject | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($receiptFullPath, $receiptJson, (New-Object System.Text.UTF8Encoding($false)))
$receiptSha256 = Get-FileSha256 $receiptFullPath

return [pscustomobject]@{
    receiptPath = $receiptFullPath
    receiptSha256 = $receiptSha256
    transportBrokerHostBindingAccepted = $true
    currentProcessId = $currentProcessId
    currentProcessStartTimeUtc = $currentProcessStartTimeUtc
    executablePath = [System.IO.Path]::GetFullPath($currentMainModulePath)
    executableSha256 = $currentExecutableSha256
    powershellVersion = $currentVersion
    frameworkDescription = $currentFramework
    productionOdrConsumerAccepted = $false
}
