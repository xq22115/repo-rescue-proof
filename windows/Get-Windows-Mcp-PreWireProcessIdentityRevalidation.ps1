param(
    [Parameter(Mandatory = $true)][string]$SpawnedProcessIdentityReceiptPath,
    [Parameter(Mandatory = $true)][string]$ExpectedSpawnedProcessIdentityReceiptSha256,
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

function Get-PropertyValue($Object, [string]$Name) {
    Assert-True ($null -ne $Object) "Object for property '$Name' is null."
    $property = $Object.PSObject.Properties[$Name]
    Assert-True ($null -ne $property) "Missing required property '$Name'."
    return $property.Value
}

function Parse-UtcTimestamp([string]$Value, [string]$FieldPath) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($Value)) "$FieldPath is required."
    $parsed = [datetimeoffset]::MinValue
    $ok = [datetimeoffset]::TryParse(
        $Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )
    Assert-True $ok "$FieldPath must be an ISO-8601 timestamp."
    Assert-True ($parsed.Offset -eq [timespan]::Zero) "$FieldPath must represent UTC (offset 00:00 / Z)."
    return $parsed.ToUniversalTime()
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Get-Windows-Mcp-PreWireProcessIdentityRevalidation.ps1 only supports Windows.'
}

$sourceReceiptFullPath = [System.IO.Path]::GetFullPath($SpawnedProcessIdentityReceiptPath)
Assert-True (Test-Path -LiteralPath $sourceReceiptFullPath -PathType Leaf) 'Spawned-process identity receipt was not found.'
$expectedSourceReceiptSha = Assert-Sha256 -Value $ExpectedSpawnedProcessIdentityReceiptSha256 -FieldPath 'ExpectedSpawnedProcessIdentityReceiptSha256'
$sourceReceiptShaBefore = (Get-FileHash -LiteralPath $sourceReceiptFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-True ($sourceReceiptShaBefore -eq $expectedSourceReceiptSha) 'Spawned-process identity receipt SHA-256 does not match the expected external digest.'

$sourceReceipt = (Get-Content -LiteralPath $sourceReceiptFullPath -Raw) | ConvertFrom-Json
$component = [string](Get-PropertyValue $sourceReceipt 'component')
Assert-True ($component -eq 'windows-mcp-spawned-process-identity-evidence') 'Unexpected spawned-process identity receipt component.'
$schemaVersion = [int](Get-PropertyValue $sourceReceipt 'schemaVersion')
Assert-True ($schemaVersion -eq 1) 'Unsupported spawned-process identity receipt schema version.'

$acceptance = Get-PropertyValue $sourceReceipt 'acceptanceBoundary'
Assert-True ([bool](Get-PropertyValue $acceptance 'spawnedProcessIdentityAccepted')) 'Spawned-process identity receipt is not accepted.'
Assert-True ([bool](Get-PropertyValue $acceptance 'processStartTimeBoundToSpawnWindow')) 'Spawned-process identity receipt did not bind StartTime to the spawn window.'
Assert-True ([bool](Get-PropertyValue $acceptance 'processImagePathMatchesExpectedExecutable')) 'Spawned-process identity receipt did not bind image path to the expected executable.'
Assert-True ([bool](Get-PropertyValue $acceptance 'processImageBackingFileSha256MatchesExpected')) 'Spawned-process identity receipt did not bind image backing-file SHA-256.'
Assert-True ([bool](Get-PropertyValue $acceptance 'processStillRunningAtReceiptGeneration')) 'Spawned-process identity receipt did not observe the process as running.'

$expectedExecutable = Get-PropertyValue $sourceReceipt 'expectedExecutable'
$expectedPath = [System.IO.Path]::GetFullPath([string](Get-PropertyValue $expectedExecutable 'path'))
$expectedExecutableSha = Assert-Sha256 -Value ([string](Get-PropertyValue $expectedExecutable 'sha256')) -FieldPath 'spawnedProcessIdentity.expectedExecutable.sha256'
Assert-True (Test-Path -LiteralPath $expectedPath -PathType Leaf) 'Expected executable from spawned-process receipt no longer exists.'
Assert-True (((Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash.ToLowerInvariant()) -eq $expectedExecutableSha) 'Expected executable bytes changed before pre-wire process revalidation.'

$observedProcess = Get-PropertyValue $sourceReceipt 'observedProcess'
$targetProcessId = [int](Get-PropertyValue $observedProcess 'pid')
Assert-True ($targetProcessId -gt 0) 'Spawned-process receipt PID must be a positive integer.'
$expectedStartTime = Parse-UtcTimestamp -Value ([string](Get-PropertyValue $observedProcess 'startTimeUtc')) -FieldPath 'spawnedProcessIdentity.observedProcess.startTimeUtc'
$expectedObservedPath = [System.IO.Path]::GetFullPath([string](Get-PropertyValue $observedProcess 'imagePath'))
$expectedObservedSha = Assert-Sha256 -Value ([string](Get-PropertyValue $observedProcess 'imageBackingFileSha256')) -FieldPath 'spawnedProcessIdentity.observedProcess.imageBackingFileSha256'
Assert-True ($expectedObservedPath.Equals($expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) 'Spawned-process receipt observed image path no longer agrees with its expected executable path.'
Assert-True ($expectedObservedSha -eq $expectedExecutableSha) 'Spawned-process receipt observed image SHA-256 no longer agrees with its expected executable SHA-256.'

$process = Get-Process -Id $targetProcessId -ErrorAction Stop
$process.Refresh()
Assert-True (-not $process.HasExited) "Process $targetProcessId exited before pre-wire identity revalidation."

$livePath = $null
try { $livePath = [string]$process.Path } catch { }
if ([string]::IsNullOrWhiteSpace($livePath)) {
    try { $livePath = [string]$process.MainModule.FileName } catch { }
}
Assert-True (-not [string]::IsNullOrWhiteSpace($livePath)) "Unable to read live process image path for PID $targetProcessId."
$livePath = [System.IO.Path]::GetFullPath($livePath)
Assert-True ($livePath.Equals($expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) 'Live process image path no longer matches the accepted spawned-process receipt.'

$liveBackingSha = (Get-FileHash -LiteralPath $livePath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-True ($liveBackingSha -eq $expectedExecutableSha) 'Live process image backing-file SHA-256 no longer matches the accepted spawned-process receipt.'

$liveStartTime = ([datetimeoffset]$process.StartTime).ToUniversalTime()
Assert-True ($liveStartTime.UtcTicks -eq $expectedStartTime.UtcTicks) 'Live PID StartTime no longer matches the accepted spawned-process lifetime.'

$process.Refresh()
Assert-True (-not $process.HasExited) "Process $targetProcessId exited during pre-wire identity revalidation."

$sourceReceiptShaAfter = (Get-FileHash -LiteralPath $sourceReceiptFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-True ($sourceReceiptShaAfter -eq $expectedSourceReceiptSha) 'Spawned-process identity receipt bytes changed during pre-wire process revalidation.'
$expectedExecutableShaAfter = (Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-True ($expectedExecutableShaAfter -eq $expectedExecutableSha) 'Expected executable bytes changed during pre-wire process revalidation.'

$receiptFullPath = [System.IO.Path]::GetFullPath($ReceiptPath)
$receiptDir = Split-Path -Parent $receiptFullPath
if (-not [string]::IsNullOrWhiteSpace($receiptDir) -and -not (Test-Path -LiteralPath $receiptDir -PathType Container)) {
    New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
}

$receipt = [ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-pre-wire-process-identity-revalidation'
    generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    sourceSpawnedProcessIdentity = [ordered]@{
        receiptPath = $sourceReceiptFullPath
        receiptSha256 = $expectedSourceReceiptSha
        stableAcrossRevalidation = $true
    }
    observedProcess = [ordered]@{
        pid = $targetProcessId
        startTimeUtc = $liveStartTime.ToString('o')
        imagePath = $livePath
        imageBackingFileSha256 = $liveBackingSha
        stillRunningAtRevalidation = $true
    }
    acceptanceBoundary = [ordered]@{
        preWireProcessIdentityRevalidationAccepted = $true
        samePidObserved = $true
        sameProcessStartTimeObserved = $true
        sameImagePathObserved = $true
        sameImageBackingFileSha256Observed = $true
        sourceReceiptStableAcrossRevalidation = $true
        expectedExecutableStableAcrossRevalidation = $true
        processStillRunningAtRevalidation = $true
        processLifetimeRaceFree = $false
        createProcessExecutableBindingAtomicityProven = $false
        exactLoadedImageBytesCryptographicallyProven = $false
        processModulesEnumerationCompletenessProven = $false
        dependentModuleTrustAccepted = $false
        downstreamMcpServerPhysicalIdentityAccepted = $false
        mcpProtocolRuntimeAccepted = $false
        semanticToolAccepted = $false
        windowsFinalStateAccepted = $false
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($receiptFullPath, ($receipt | ConvertTo-Json -Depth 10), $utf8NoBom)
$receiptSha = (Get-FileHash -LiteralPath $receiptFullPath -Algorithm SHA256).Hash.ToLowerInvariant()

[pscustomobject][ordered]@{
    receiptPath = $receiptFullPath
    receiptSha256 = $receiptSha
    processId = $targetProcessId
    processStartTimeUtc = $liveStartTime.ToString('o')
    imagePath = $livePath
    imageBackingFileSha256 = $liveBackingSha
    preWireProcessIdentityRevalidationAccepted = $true
    processStillRunningAtRevalidation = $true
    processLifetimeRaceFree = $false
    downstreamMcpServerPhysicalIdentityAccepted = $false
    semanticToolAccepted = $false
    windowsFinalStateAccepted = $false
}
