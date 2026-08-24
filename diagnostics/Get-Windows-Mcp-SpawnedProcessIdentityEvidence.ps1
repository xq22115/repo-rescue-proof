param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][string]$ExpectedExecutablePath,
    [Parameter(Mandatory = $true)][string]$ExpectedExecutableSha256,
    [Parameter(Mandatory = $true)][string]$SpawnWindowStartUtc,
    [Parameter(Mandatory = $true)][string]$SpawnWindowEndUtc,
    [ValidateRange(0, 60)][int]$AllowedClockSkewSeconds = 5,
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
    throw 'Get-Windows-Mcp-SpawnedProcessIdentityEvidence.ps1 only supports Windows.'
}
Assert-True ($ProcessId -gt 0) 'ProcessId must be a positive integer.'

$expectedPath = [System.IO.Path]::GetFullPath($ExpectedExecutablePath)
Assert-True (Test-Path -LiteralPath $expectedPath -PathType Leaf) "Expected executable does not exist: $expectedPath"
$expectedSha = Assert-Sha256 -Value $ExpectedExecutableSha256 -FieldPath 'ExpectedExecutableSha256'
$currentExpectedSha = (Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-True ($currentExpectedSha -eq $expectedSha) 'Expected executable SHA-256 no longer matches current bytes.'

$spawnStart = Parse-UtcTimestamp -Value $SpawnWindowStartUtc -FieldPath 'SpawnWindowStartUtc'
$spawnEnd = Parse-UtcTimestamp -Value $SpawnWindowEndUtc -FieldPath 'SpawnWindowEndUtc'
Assert-True ($spawnEnd -ge $spawnStart) 'SpawnWindowEndUtc must not precede SpawnWindowStartUtc.'
$lowerBound = $spawnStart.AddSeconds(-1 * $AllowedClockSkewSeconds)
$upperBound = $spawnEnd.AddSeconds($AllowedClockSkewSeconds)

$process = Get-Process -Id $ProcessId -ErrorAction Stop
$process.Refresh()
Assert-True (-not $process.HasExited) "Process $ProcessId exited before identity evidence could be captured."

$processPath = $null
try { $processPath = [string]$process.Path } catch { }
if ([string]::IsNullOrWhiteSpace($processPath)) {
    try { $processPath = [string]$process.MainModule.FileName } catch { }
}
Assert-True (-not [string]::IsNullOrWhiteSpace($processPath)) "Unable to read process image path for PID $ProcessId."
$processPath = [System.IO.Path]::GetFullPath($processPath)
Assert-True ($processPath.Equals($expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) "Spawned process image path mismatch. expected='$expectedPath' actual='$processPath'"

$processBackingSha = (Get-FileHash -LiteralPath $processPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-True ($processBackingSha -eq $expectedSha) 'Spawned process image backing-file SHA-256 does not match the expected executable SHA-256.'

$processStart = ([datetimeoffset]$process.StartTime).ToUniversalTime()
Assert-True ($processStart -ge $lowerBound) "Spawned process StartTime predates the accepted spawn window. start='$($processStart.ToString('o'))' lower='$($lowerBound.ToString('o'))'"
Assert-True ($processStart -le $upperBound) "Spawned process StartTime exceeds the accepted spawn window. start='$($processStart.ToString('o'))' upper='$($upperBound.ToString('o'))'"

$process.Refresh()
Assert-True (-not $process.HasExited) "Process $ProcessId exited before identity evidence receipt generation."

$receiptFullPath = [System.IO.Path]::GetFullPath($ReceiptPath)
$receiptDir = Split-Path -Parent $receiptFullPath
if (-not [string]::IsNullOrWhiteSpace($receiptDir) -and -not (Test-Path -LiteralPath $receiptDir -PathType Container)) {
    New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
}

$receipt = [ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-spawned-process-identity-evidence'
    generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    expectedExecutable = [ordered]@{
        path = $expectedPath
        sha256 = $expectedSha
    }
    spawnWindow = [ordered]@{
        startUtc = $spawnStart.ToString('o')
        endUtc = $spawnEnd.ToString('o')
        allowedClockSkewSeconds = $AllowedClockSkewSeconds
        acceptedLowerBoundUtc = $lowerBound.ToString('o')
        acceptedUpperBoundUtc = $upperBound.ToString('o')
    }
    observedProcess = [ordered]@{
        pid = $ProcessId
        startTimeUtc = $processStart.ToString('o')
        imagePath = $processPath
        imageBackingFileSha256 = $processBackingSha
        stillRunningAtReceiptGeneration = $true
    }
    acceptanceBoundary = [ordered]@{
        spawnedProcessIdentityAccepted = $true
        processStartTimeBoundToSpawnWindow = $true
        processImagePathMatchesExpectedExecutable = $true
        processImageBackingFileSha256MatchesExpected = $true
        processStillRunningAtReceiptGeneration = $true
        processLifetimeRaceFree = $false
        createProcessExecutableBindingAtomicityProven = $false
        exactLoadedImageBytesCryptographicallyProven = $false
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
    processId = $ProcessId
    processStartTimeUtc = $processStart.ToString('o')
    spawnedProcessIdentityAccepted = $true
    processStartTimeBoundToSpawnWindow = $true
    exactLoadedImageBytesCryptographicallyProven = $false
    downstreamMcpServerPhysicalIdentityAccepted = $false
    semanticToolAccepted = $false
    windowsFinalStateAccepted = $false
}
