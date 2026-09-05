param(
    [Parameter(Mandatory = $true)][string]$SpawnedProcessIdentityReceiptPath,
    [Parameter(Mandatory = $true)][string]$SpawnedProcessIdentityReceiptSha256,
    [string]$TrustedInstallRoot,
    [string]$ModuleInventoryReceiptPath,
    [Parameter(Mandatory = $true)][string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Sha256([string]$Value, [string]$FieldPath) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($Value)) "$FieldPath is required."
    Assert-True ($Value -match '^[0-9A-Fa-f]{64}$') "$FieldPath must be a 64-hex SHA-256 string."
    return $Value.ToLowerInvariant()
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RequiredProperty($Object, [string]$Name, [string]$FieldPath) {
    Assert-True ($null -ne $Object) "$FieldPath parent object is required."
    $property = $Object.PSObject.Properties[$Name]
    Assert-True ($null -ne $property) "$FieldPath is required."
    return $property.Value
}

function Get-RequiredString($Object, [string]$Name, [string]$FieldPath) {
    $value = Get-RequiredProperty -Object $Object -Name $Name -FieldPath $FieldPath
    Assert-True ($value -is [string]) "$FieldPath must be a JSON string."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$value)) "$FieldPath must not be empty."
    return [string]$value
}

function Get-RequiredBoolean($Object, [string]$Name, [string]$FieldPath) {
    $value = Get-RequiredProperty -Object $Object -Name $Name -FieldPath $FieldPath
    Assert-True ($value -is [bool]) "$FieldPath must be a JSON boolean."
    return [bool]$value
}

function Get-RequiredInteger($Object, [string]$Name, [string]$FieldPath) {
    $value = Get-RequiredProperty -Object $Object -Name $Name -FieldPath $FieldPath
    Assert-True ($value -is [int] -or $value -is [long] -or $value -is [int64]) "$FieldPath must be a JSON integer."
    return [int64]$value
}

function Get-RequiredObject($Object, [string]$Name, [string]$FieldPath) {
    $value = Get-RequiredProperty -Object $Object -Name $Name -FieldPath $FieldPath
    Assert-True ($null -ne $value -and -not ($value -is [string]) -and -not ($value -is [System.Collections.IEnumerable] -and $value -isnot [pscustomobject])) "$FieldPath must be a JSON object."
    return $value
}

function Parse-UtcTimestamp([string]$Value, [string]$FieldPath) {
    $parsed = [datetimeoffset]::MinValue
    $ok = [datetimeoffset]::TryParse(
        $Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )
    Assert-True $ok "$FieldPath must be an ISO-8601 timestamp."
    return $parsed.ToUniversalTime()
}

function Get-LiveProcessObservation([int]$ProcessId, [string]$ExpectedPath, [string]$ExpectedSha256, [datetimeoffset]$ExpectedStartUtc, [string]$Phase) {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    try {
        $process.Refresh()
        Assert-True (-not $process.HasExited) "${Phase}: process $ProcessId is no longer running."
        $path = $null
        try { $path = [string]$process.Path } catch { }
        if ([string]::IsNullOrWhiteSpace($path)) {
            try { $path = [string]$process.MainModule.FileName } catch { }
        }
        Assert-True (-not [string]::IsNullOrWhiteSpace($path)) "${Phase}: unable to read process image path for PID $ProcessId."
        $path = [System.IO.Path]::GetFullPath($path)
        Assert-True ($path.Equals($ExpectedPath, [System.StringComparison]::OrdinalIgnoreCase)) "${Phase}: live process image path no longer matches spawned-process identity."
        $sha = Get-FileSha256 $path
        Assert-True ($sha -eq $ExpectedSha256) "${Phase}: live process image SHA-256 no longer matches spawned-process identity."
        $start = ([datetimeoffset]$process.StartTime).ToUniversalTime()
        Assert-True ($start.UtcTicks -eq $ExpectedStartUtc.UtcTicks) "${Phase}: live process StartTime no longer matches spawned-process identity; PID reuse or lifetime drift is not accepted."
        return [pscustomobject][ordered]@{
            pid = $ProcessId
            startTimeUtc = $start.ToString('o')
            imagePath = $path
            imageFileSha256 = $sha
            stillRunning = $true
        }
    } finally {
        $process.Dispose()
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Get-Windows-Mcp-SpawnBoundProcessModuleInventoryEvidence.ps1 only supports Windows.'
}

$spawnReceiptFullPath = [System.IO.Path]::GetFullPath($SpawnedProcessIdentityReceiptPath)
Assert-True (Test-Path -LiteralPath $spawnReceiptFullPath -PathType Leaf) 'Spawned-process identity receipt was not found.'
$expectedSpawnReceiptSha = Assert-Sha256 -Value $SpawnedProcessIdentityReceiptSha256 -FieldPath 'SpawnedProcessIdentityReceiptSha256'
$observedSpawnReceiptSha = Get-FileSha256 $spawnReceiptFullPath
Assert-True ($observedSpawnReceiptSha -eq $expectedSpawnReceiptSha) 'Spawned-process identity receipt SHA-256 mismatch.'

$spawnReceipt = (Get-Content -LiteralPath $spawnReceiptFullPath -Raw) | ConvertFrom-Json
$spawnComponent = Get-RequiredString -Object $spawnReceipt -Name 'component' -FieldPath 'spawnReceipt.component'
Assert-True ($spawnComponent -eq 'windows-mcp-spawned-process-identity-evidence') 'Unexpected spawned-process identity receipt component.'
$spawnSchema = Get-RequiredInteger -Object $spawnReceipt -Name 'schemaVersion' -FieldPath 'spawnReceipt.schemaVersion'
Assert-True ($spawnSchema -eq 1) 'Unexpected spawned-process identity receipt schemaVersion.'
$spawnBoundary = Get-RequiredObject -Object $spawnReceipt -Name 'acceptanceBoundary' -FieldPath 'spawnReceipt.acceptanceBoundary'
foreach ($requiredTrue in @('spawnedProcessIdentityAccepted','processStartTimeBoundToSpawnWindow','processImagePathMatchesExpectedExecutable','processImageBackingFileSha256MatchesExpected','processStillRunningAtReceiptGeneration')) {
    Assert-True (Get-RequiredBoolean -Object $spawnBoundary -Name $requiredTrue -FieldPath "spawnReceipt.acceptanceBoundary.$requiredTrue") "Spawned-process identity receipt did not accept '$requiredTrue'."
}

$spawnProcess = Get-RequiredObject -Object $spawnReceipt -Name 'observedProcess' -FieldPath 'spawnReceipt.observedProcess'
$processId = [int](Get-RequiredInteger -Object $spawnProcess -Name 'pid' -FieldPath 'spawnReceipt.observedProcess.pid')
Assert-True ($processId -gt 0) 'Spawned-process identity receipt PID must be positive.'
$spawnStartText = Get-RequiredString -Object $spawnProcess -Name 'startTimeUtc' -FieldPath 'spawnReceipt.observedProcess.startTimeUtc'
$spawnStart = Parse-UtcTimestamp -Value $spawnStartText -FieldPath 'spawnReceipt.observedProcess.startTimeUtc'
$expectedExecutablePath = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $spawnProcess -Name 'imagePath' -FieldPath 'spawnReceipt.observedProcess.imagePath'))
$expectedExecutableSha = Assert-Sha256 -Value (Get-RequiredString -Object $spawnProcess -Name 'imageBackingFileSha256' -FieldPath 'spawnReceipt.observedProcess.imageBackingFileSha256') -FieldPath 'spawnReceipt.observedProcess.imageBackingFileSha256'

$preInventoryLive = Get-LiveProcessObservation -ProcessId $processId -ExpectedPath $expectedExecutablePath -ExpectedSha256 $expectedExecutableSha -ExpectedStartUtc $spawnStart -Phase 'Before module inventory'

$inventoryScript = Join-Path $PSScriptRoot 'Get-Windows-ProcessModuleInventory.ps1'
Assert-True (Test-Path -LiteralPath $inventoryScript -PathType Leaf) 'Get-Windows-ProcessModuleInventory.ps1 is required.'
$moduleReceiptFullPath = if ([string]::IsNullOrWhiteSpace($ModuleInventoryReceiptPath)) {
    [System.IO.Path]::GetFullPath($ReceiptPath + '.module-inventory.json')
} else {
    [System.IO.Path]::GetFullPath($ModuleInventoryReceiptPath)
}
$moduleArgs = @{
    ProcessId = $processId
    ExpectedExecutablePath = $expectedExecutablePath
    ExpectedExecutableSha256 = $expectedExecutableSha
    OutputReceiptPath = $moduleReceiptFullPath
}
if (-not [string]::IsNullOrWhiteSpace($TrustedInstallRoot)) {
    $moduleArgs.TrustedInstallRoot = $TrustedInstallRoot
}
$moduleResult = & $inventoryScript @moduleArgs
Assert-True ([bool]$moduleResult.moduleInventorySnapshotAccepted) 'Process module inventory was not accepted.'
Assert-True ([bool]$moduleResult.processModulesSameArchitecturePrerequisiteAccepted) 'Process module inventory did not accept the same-architecture prerequisite.'
Assert-True (-not [bool]$moduleResult.processModulesEnumerationCompletenessProven) 'Process module inventory must not overclaim enumeration completeness.'
Assert-True (Test-Path -LiteralPath $moduleReceiptFullPath -PathType Leaf) 'Process module inventory receipt was not persisted.'
$moduleReceiptSha = Get-FileSha256 $moduleReceiptFullPath
Assert-Sha256 -Value $moduleReceiptSha -FieldPath 'moduleInventory.receiptSha256' | Out-Null

$moduleReceipt = (Get-Content -LiteralPath $moduleReceiptFullPath -Raw) | ConvertFrom-Json
$moduleComponent = Get-RequiredString -Object $moduleReceipt -Name 'component' -FieldPath 'moduleReceipt.component'
Assert-True ($moduleComponent -eq 'windows-process-module-inventory') 'Unexpected process module inventory receipt component.'
$moduleSchema = Get-RequiredInteger -Object $moduleReceipt -Name 'schemaVersion' -FieldPath 'moduleReceipt.schemaVersion'
Assert-True ($moduleSchema -eq 2) 'Unexpected process module inventory receipt schemaVersion.'
$moduleProcess = Get-RequiredObject -Object $moduleReceipt -Name 'process' -FieldPath 'moduleReceipt.process'
$modulePid = [int](Get-RequiredInteger -Object $moduleProcess -Name 'pid' -FieldPath 'moduleReceipt.process.pid')
Assert-True ($modulePid -eq $processId) 'Process module inventory PID differs from the spawned-process identity receipt.'
$moduleStart = Parse-UtcTimestamp -Value (Get-RequiredString -Object $moduleProcess -Name 'startTimeUtc' -FieldPath 'moduleReceipt.process.startTimeUtc') -FieldPath 'moduleReceipt.process.startTimeUtc'
Assert-True ($moduleStart.UtcTicks -eq $spawnStart.UtcTicks) 'Process module inventory StartTime differs from the spawned-process lifetime.'
$moduleImagePath = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $moduleProcess -Name 'imagePath' -FieldPath 'moduleReceipt.process.imagePath'))
Assert-True ($moduleImagePath.Equals($expectedExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)) 'Process module inventory image path differs from the spawned-process identity.'
$moduleImageSha = Assert-Sha256 -Value (Get-RequiredString -Object $moduleProcess -Name 'imageFileSha256' -FieldPath 'moduleReceipt.process.imageFileSha256') -FieldPath 'moduleReceipt.process.imageFileSha256'
Assert-True ($moduleImageSha -eq $expectedExecutableSha) 'Process module inventory image SHA-256 differs from the spawned-process identity.'
$architectureEvidence = Get-RequiredObject -Object $moduleReceipt -Name 'processModulesArchitecture' -FieldPath 'moduleReceipt.processModulesArchitecture'
Assert-True (Get-RequiredBoolean -Object $architectureEvidence -Name 'sameArchitecturePrerequisiteAccepted' -FieldPath 'moduleReceipt.processModulesArchitecture.sameArchitecturePrerequisiteAccepted') 'Process module inventory architecture prerequisite was not accepted.'
Assert-True (-not (Get-RequiredBoolean -Object $architectureEvidence -Name 'enumerationCompletenessProven' -FieldPath 'moduleReceipt.processModulesArchitecture.enumerationCompletenessProven')) 'Process module inventory architecture evidence must not claim completeness.'
$moduleBoundary = Get-RequiredObject -Object $moduleReceipt -Name 'acceptanceBoundary' -FieldPath 'moduleReceipt.acceptanceBoundary'
foreach ($requiredTrue in @('processImageIdentityAccepted','processModulesSameArchitecturePrerequisiteAccepted','moduleEnumerationAccepted','moduleInventorySnapshotAccepted','mainExecutablePresentExactlyOnce')) {
    Assert-True (Get-RequiredBoolean -Object $moduleBoundary -Name $requiredTrue -FieldPath "moduleReceipt.acceptanceBoundary.$requiredTrue") "Module inventory receipt did not accept '$requiredTrue'."
}
foreach ($requiredFalse in @('processModulesEnumerationCompletenessProven','dependentModuleTrustAccepted','dynamicModulesLoadedAfterSnapshotCovered','moduleSetStableAcrossMultipleSnapshots','exactLoadedModuleBytesCryptographicallyProven','semanticMcpFunctionalityAccepted','windowsFinalStateAccepted')) {
    Assert-True (-not (Get-RequiredBoolean -Object $moduleBoundary -Name $requiredFalse -FieldPath "moduleReceipt.acceptanceBoundary.$requiredFalse")) "Module inventory receipt must not overclaim '$requiredFalse'."
}
$moduleInventory = Get-RequiredObject -Object $moduleReceipt -Name 'moduleInventory' -FieldPath 'moduleReceipt.moduleInventory'
$moduleCount = [int](Get-RequiredInteger -Object $moduleInventory -Name 'moduleCount' -FieldPath 'moduleReceipt.moduleInventory.moduleCount')
Assert-True ($moduleCount -gt 0) 'Process module inventory must contain at least one module.'
$moduleFingerprint = Assert-Sha256 -Value (Get-RequiredString -Object $moduleInventory -Name 'moduleSetFingerprintSha256' -FieldPath 'moduleReceipt.moduleInventory.moduleSetFingerprintSha256') -FieldPath 'moduleReceipt.moduleInventory.moduleSetFingerprintSha256'

Assert-True ((Get-FileSha256 $spawnReceiptFullPath) -eq $expectedSpawnReceiptSha) 'Spawned-process identity receipt bytes changed during module inventory.'
Assert-True ((Get-FileSha256 $moduleReceiptFullPath) -eq $moduleReceiptSha) 'Process module inventory receipt bytes changed before spawn-bound receipt generation.'
$postInventoryLive = Get-LiveProcessObservation -ProcessId $processId -ExpectedPath $expectedExecutablePath -ExpectedSha256 $expectedExecutableSha -ExpectedStartUtc $spawnStart -Phase 'After module inventory'

$receiptFullPath = [System.IO.Path]::GetFullPath($ReceiptPath)
$receiptDir = Split-Path -Parent $receiptFullPath
if (-not [string]::IsNullOrWhiteSpace($receiptDir) -and -not (Test-Path -LiteralPath $receiptDir -PathType Container)) {
    New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
}
$receipt = [ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-spawn-bound-process-module-inventory-evidence'
    generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    spawnedProcessIdentity = [ordered]@{
        receiptPath = $spawnReceiptFullPath
        receiptSha256 = $expectedSpawnReceiptSha
        pid = $processId
        startTimeUtc = $spawnStart.ToString('o')
        imagePath = $expectedExecutablePath
        imageFileSha256 = $expectedExecutableSha
    }
    moduleInventory = [ordered]@{
        receiptPath = $moduleReceiptFullPath
        receiptSha256 = $moduleReceiptSha
        moduleCount = $moduleCount
        moduleSetFingerprintSha256 = $moduleFingerprint
        processModulesSameArchitecturePrerequisiteAccepted = $true
        processModulesEnumerationCompletenessProven = $false
    }
    lifetimeRebind = [ordered]@{
        beforeModuleInventory = $preInventoryLive
        afterModuleInventory = $postInventoryLive
    }
    acceptanceBoundary = [ordered]@{
        spawnedProcessIdentityReceiptAccepted = $true
        liveProcessReboundBeforeModuleInventory = $true
        moduleInventoryReceiptAccepted = $true
        moduleInventoryBoundToSpawnedProcessLifetime = $true
        liveProcessReboundAfterModuleInventory = $true
        processModulesSameArchitecturePrerequisiteAccepted = $true
        processModulesEnumerationCompletenessProven = $false
        processLifetimeRaceFree = $false
        exactLoadedImageBytesCryptographicallyProven = $false
        dependentModuleTrustAccepted = $false
        dynamicModulesLoadedAfterSnapshotCovered = $false
        moduleSetStableAcrossMultipleSnapshots = $false
        downstreamMcpServerPhysicalIdentityAccepted = $false
        mcpProtocolRuntimeAccepted = $false
        semanticToolAccepted = $false
        windowsFinalStateAccepted = $false
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($receiptFullPath, ($receipt | ConvertTo-Json -Depth 12), $utf8NoBom)
$receiptSha = Get-FileSha256 $receiptFullPath

[pscustomobject][ordered]@{
    receiptPath = $receiptFullPath
    receiptSha256 = $receiptSha
    processId = $processId
    processStartTimeUtc = $spawnStart.ToString('o')
    moduleInventoryBoundToSpawnedProcessLifetime = $true
    processModulesSameArchitecturePrerequisiteAccepted = $true
    processModulesEnumerationCompletenessProven = $false
    moduleSetFingerprintSha256 = $moduleFingerprint
    moduleCount = $moduleCount
    processLifetimeRaceFree = $false
    dependentModuleTrustAccepted = $false
    semanticToolAccepted = $false
    windowsFinalStateAccepted = $false
}
