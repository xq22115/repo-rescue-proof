param(
    [Parameter(Mandatory = $true)][string]$LeasePath,
    [Parameter(Mandatory = $true)][string]$ExpectedLeaseSha256,
    [Parameter(Mandatory = $true)][string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Get-BraintrustStrictJsonScalar.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-FileSha256([string]$Path) {
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "Required file does not exist: $Path"
    return ([string](Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToLowerInvariant()
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-Sha256([string]$Value, [string]$FieldPath) {
    Assert-True ($Value -match '^[0-9a-fA-F]{64}$') "$FieldPath must be a 64-character SHA-256 value."
    return $Value.ToLowerInvariant()
}

function ConvertTo-UtcTimestamp([object]$Value, [string]$FieldPath) {
    if ($Value -is [datetimeoffset]) { return ([datetimeoffset]$Value).ToUniversalTime() }
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) { $dt = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc) }
        return ([datetimeoffset]$dt.ToUniversalTime())
    }
    $parsed = [datetimeoffset]::MinValue
    $ok = [datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
    Assert-True $ok "$FieldPath must be an ISO-8601 timestamp."
    Assert-True ($parsed.Offset -eq [timespan]::Zero) "$FieldPath must represent UTC."
    return $parsed.ToUniversalTime()
}

function Read-StrictJsonObject([string]$Path, [string]$FieldPath) {
    try {
        return Assert-BraintrustJsonObjectValue -Value ((Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json -ErrorAction Stop) -FieldPath $FieldPath
    } catch {
        throw "$FieldPath is not valid strict JSON input: $($_.Exception.Message)"
    }
}

function Assert-PathEquivalent([string]$Actual, [string]$Expected, [string]$Message) {
    $a = Get-FullPath $Actual
    $e = Get-FullPath $Expected
    Assert-True ([string]::Equals($a, $e, [System.StringComparison]::OrdinalIgnoreCase)) $Message
}

Assert-True ($env:OS -eq 'Windows_NT') 'Stdio single-flight lease recovery evidence only supports Windows.'

$leaseFullPath = Get-FullPath $LeasePath
$receiptFullPath = Get-FullPath $ReceiptPath
$expectedLeaseSha = Assert-Sha256 $ExpectedLeaseSha256 'ExpectedLeaseSha256'
$leaseSha = Get-FileSha256 $leaseFullPath
Assert-True ($leaseSha -eq $expectedLeaseSha) 'Single-flight lease differs from the externally expected digest.'

$lease = Read-StrictJsonObject $leaseFullPath 'singleFlightLease'
$schemaVersion = Get-BraintrustRequiredJsonInteger -Object $lease -Name 'schemaVersion' -FieldPath 'singleFlightLease.schemaVersion'
Assert-True ($schemaVersion -eq 1) 'Unsupported single-flight lease schema version.'
Assert-True ((Get-BraintrustRequiredJsonString -Object $lease -Name 'component' -FieldPath 'singleFlightLease.component') -eq 'windows-mcp-stdio-single-flight-lease') 'Unexpected single-flight lease component.'
$protocolVersion = Get-BraintrustRequiredJsonString -Object $lease -Name 'expectedProtocolVersion' -FieldPath 'singleFlightLease.expectedProtocolVersion'
$transport = Get-BraintrustRequiredJsonString -Object $lease -Name 'transport' -FieldPath 'singleFlightLease.transport'
Assert-True ($protocolVersion -eq '2026-07-28') 'Unsupported single-flight lease protocol version.'
Assert-True ($transport -eq 'stdio') 'Unsupported single-flight lease transport.'
$sessionKeySha = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $lease -Name 'sessionKeySha256' -FieldPath 'singleFlightLease.sessionKeySha256') 'singleFlightLease.sessionKeySha256'

$processIdentity = Get-BraintrustRequiredJsonObject -Object $lease -Name 'processIdentity' -FieldPath 'singleFlightLease.processIdentity'
$pid64 = Get-BraintrustRequiredJsonInteger -Object $processIdentity -Name 'processId' -FieldPath 'singleFlightLease.processIdentity.processId'
Assert-True ($pid64 -gt 0 -and $pid64 -le [int]::MaxValue) 'singleFlightLease.processIdentity.processId is invalid.'
$boundPid = [int]$pid64
$boundStartUtc = ConvertTo-UtcTimestamp (Get-BraintrustRequiredJsonTimestampString -Object $processIdentity -Name 'processStartTimeUtc' -FieldPath 'singleFlightLease.processIdentity.processStartTimeUtc') 'singleFlightLease.processIdentity.processStartTimeUtc'
$boundImagePath = Get-FullPath (Get-BraintrustRequiredJsonString -Object $processIdentity -Name 'imagePath' -FieldPath 'singleFlightLease.processIdentity.imagePath')
$boundImageSha = Assert-Sha256 (Get-BraintrustRequiredJsonString -Object $processIdentity -Name 'imageBackingFileSha256' -FieldPath 'singleFlightLease.processIdentity.imageBackingFileSha256') 'singleFlightLease.processIdentity.imageBackingFileSha256'

$separator = [char]31
$keyMaterial = [string]::Join([string]$separator, @(
    $transport,
    $protocolVersion,
    [string]$boundPid,
    [string]$boundStartUtc.UtcTicks,
    $boundImagePath.ToLowerInvariant(),
    $boundImageSha
))
$recomputedSessionKey = Get-BytesSha256 ([System.Text.UTF8Encoding]::new($false).GetBytes($keyMaterial))
Assert-True ($recomputedSessionKey -eq $sessionKeySha) 'Single-flight lease sessionKeySha256 does not match its process/session identity.'
$expectedLeaf = $sessionKeySha + '.stdio-single-flight.json'
Assert-True ([string]::Equals([System.IO.Path]::GetFileName($leaseFullPath), $expectedLeaf, [System.StringComparison]::OrdinalIgnoreCase)) 'Single-flight lease filename does not match sessionKeySha256.'

$state = 'unknown'
$processObserved = $false
$observedPid = $null
$observedStartUtc = $null
$observedImagePath = $null
$observedImageSha = $null
$identityMatched = $false

$liveProcess = $null
try { $liveProcess = Get-Process -Id $boundPid -ErrorAction Stop } catch {}
if ($null -eq $liveProcess) {
    $state = 'abandoned-session-process-missing'
} else {
    $processObserved = $true
    $liveProcess.Refresh()
    if ($liveProcess.HasExited) {
        $state = 'abandoned-session-process-missing'
    } else {
        $observedPid = [int]$liveProcess.Id
        try { $observedStartUtc = ([datetimeoffset]$liveProcess.StartTime).ToUniversalTime() } catch {}
        try { $observedImagePath = [string]$liveProcess.Path } catch {}
        if ([string]::IsNullOrWhiteSpace($observedImagePath)) {
            try { $observedImagePath = [string]$liveProcess.MainModule.FileName } catch {}
        }
        if (-not [string]::IsNullOrWhiteSpace($observedImagePath)) {
            $observedImagePath = Get-FullPath $observedImagePath
            if (Test-Path -LiteralPath $observedImagePath -PathType Leaf) { $observedImageSha = Get-FileSha256 $observedImagePath }
        }

        $identityMatched = ($null -ne $observedStartUtc) -and
            ($observedStartUtc.UtcTicks -eq $boundStartUtc.UtcTicks) -and
            (-not [string]::IsNullOrWhiteSpace($observedImagePath)) -and
            ([string]::Equals($observedImagePath, $boundImagePath, [System.StringComparison]::OrdinalIgnoreCase)) -and
            ($observedImageSha -eq $boundImageSha)
        if ($identityMatched) { $state = 'live-session-busy' }
        else { $state = 'abandoned-session-identity-drift' }
    }
}

$leaseShaAfterObservation = Get-FileSha256 $leaseFullPath
Assert-True ($leaseShaAfterObservation -eq $leaseSha) 'Single-flight lease changed during recovery classification.'

$receiptDirectory = Split-Path -Parent $receiptFullPath
if ($receiptDirectory) { New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null }
$receipt = [ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-stdio-single-flight-lease-recovery-evidence'
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    leaseEvidence = [ordered]@{
        leasePath = $leaseFullPath
        leaseSha256 = $leaseSha
        sessionKeySha256 = $sessionKeySha
        expectedProtocolVersion = $protocolVersion
        transport = $transport
    }
    boundProcessIdentity = [ordered]@{
        processId = $boundPid
        processStartTimeUtc = $boundStartUtc.ToString('o')
        imagePath = $boundImagePath
        imageBackingFileSha256 = $boundImageSha
    }
    liveObservation = [ordered]@{
        processObserved = $processObserved
        processId = $observedPid
        processStartTimeUtc = if ($null -eq $observedStartUtc) { $null } else { $observedStartUtc.ToString('o') }
        imagePath = $observedImagePath
        imageBackingFileSha256 = $observedImageSha
        identityMatched = $identityMatched
    }
    recoveryClassification = [ordered]@{
        state = $state
        liveSessionBusy = ($state -eq 'live-session-busy')
        abandonedSessionProcessMissing = ($state -eq 'abandoned-session-process-missing')
        abandonedSessionIdentityDrift = ($state -eq 'abandoned-session-identity-drift')
        freshSessionRequired = ($state -ne 'live-session-busy')
        manualRecoveryRequired = ($state -ne 'live-session-busy')
    }
    acceptanceBoundary = [ordered]@{
        leaseRecoveryEvidenceAccepted = $true
        leaseIntegrityRevalidated = $true
        processSessionIdentityRecomputed = $true
        staleLeaseAutomaticallyDeleted = $false
        sameSessionReplayAuthorized = $false
        automaticRetryAccepted = $false
        crashRecoveryReplayAccepted = $false
        deliveryOutcomeKnown = $false
        exactlyOnceToolSideEffectProven = $false
        powerLossDurabilityAccepted = $false
        processLifetimeRaceFree = $false
        toolExecutionAuthorized = $false
        semanticToolAccepted = $false
        windowsFinalStateAccepted = $false
    }
}
$json = $receipt | ConvertTo-Json -Depth 30
[System.IO.File]::WriteAllText($receiptFullPath, $json, [System.Text.UTF8Encoding]::new($false))
[pscustomobject]$receipt
