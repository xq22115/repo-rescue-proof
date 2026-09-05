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

function ConvertTo-UtcTimestamp([object]$Value, [string]$FieldPath) {
    Assert-True ($null -ne $Value) "$FieldPath is required."
    if($Value -is [datetimeoffset]){ return ([datetimeoffset]$Value).ToUniversalTime() }
    if($Value -is [datetime]){
        $dt=[datetime]$Value
        if($dt.Kind -eq [System.DateTimeKind]::Unspecified){ $dt=[datetime]::SpecifyKind($dt,[System.DateTimeKind]::Utc) }
        return ([datetimeoffset]$dt.ToUniversalTime())
    }
    $text=[string]$Value
    $parsed=[datetimeoffset]::MinValue
    $ok=[datetimeoffset]::TryParse($text,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)
    Assert-True $ok "$FieldPath must be an ISO-8601 timestamp."
    Assert-True ($parsed.Offset -eq [timespan]::Zero) "$FieldPath must represent UTC."
    return $parsed.ToUniversalTime()
}

Assert-True ($env:OS -eq 'Windows_NT') 'Pre-wire process identity revalidation only supports Windows.'
$source=[IO.Path]::GetFullPath($SpawnedProcessIdentityReceiptPath)
Assert-True (Test-Path -LiteralPath $source -PathType Leaf) 'Spawned-process identity receipt was not found.'
$expectedReceiptSha=Assert-Sha256 $ExpectedSpawnedProcessIdentityReceiptSha256 'ExpectedSpawnedProcessIdentityReceiptSha256'
Assert-True (((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()) -eq $expectedReceiptSha) 'Spawned-process receipt SHA-256 mismatch.'
$r=(Get-Content -LiteralPath $source -Raw)|ConvertFrom-Json
Assert-True ([string](Get-PropertyValue $r 'component') -eq 'windows-mcp-spawned-process-identity-evidence') 'Unexpected spawned-process identity component.'
Assert-True ([int](Get-PropertyValue $r 'schemaVersion') -eq 1) 'Unsupported spawned-process identity schema.'
$a=Get-PropertyValue $r 'acceptanceBoundary'
foreach($name in @('spawnedProcessIdentityAccepted','processStartTimeBoundToSpawnWindow','processImagePathMatchesExpectedExecutable','processImageBackingFileSha256MatchesExpected','processStillRunningAtReceiptGeneration')){
    Assert-True ([bool](Get-PropertyValue $a $name)) "Spawned-process receipt prerequisite '$name' is not accepted."
}
$e=Get-PropertyValue $r 'expectedExecutable'
$expectedPath=[IO.Path]::GetFullPath([string](Get-PropertyValue $e 'path'))
$expectedExeSha=Assert-Sha256 ([string](Get-PropertyValue $e 'sha256')) 'expectedExecutable.sha256'
Assert-True (Test-Path -LiteralPath $expectedPath -PathType Leaf) 'Expected executable no longer exists.'
Assert-True (((Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash.ToLowerInvariant()) -eq $expectedExeSha) 'Expected executable bytes changed before pre-wire revalidation.'
$o=Get-PropertyValue $r 'observedProcess'
$targetProcessId=[int](Get-PropertyValue $o 'pid')
$expectedStart=ConvertTo-UtcTimestamp (Get-PropertyValue $o 'startTimeUtc') 'observedProcess.startTimeUtc'
$observedReceiptImagePath=[IO.Path]::GetFullPath([string](Get-PropertyValue $o 'imagePath'))
$observedReceiptImageSha=Assert-Sha256 ([string](Get-PropertyValue $o 'imageBackingFileSha256')) 'observedProcess.imageBackingFileSha256'
Assert-True ($observedReceiptImagePath.Equals($expectedPath,[StringComparison]::OrdinalIgnoreCase)) 'Spawned receipt image path conflicts with expected executable.'
Assert-True ($observedReceiptImageSha -eq $expectedExeSha) 'Spawned receipt image SHA conflicts with expected executable.'

$p=Get-Process -Id $targetProcessId -ErrorAction Stop
$p.Refresh(); Assert-True (-not $p.HasExited) "Process $targetProcessId exited before pre-wire revalidation."
$livePath=$null
try{$livePath=[string]$p.Path}catch{}
if([string]::IsNullOrWhiteSpace($livePath)){ try{$livePath=[string]$p.MainModule.FileName}catch{} }
Assert-True (-not [string]::IsNullOrWhiteSpace($livePath)) 'Unable to read live process image path.'
$livePath=[IO.Path]::GetFullPath($livePath)
Assert-True ($livePath.Equals($expectedPath,[StringComparison]::OrdinalIgnoreCase)) 'Live process image path changed.'
$liveSha=(Get-FileHash -LiteralPath $livePath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-True ($liveSha -eq $expectedExeSha) 'Live process backing-file SHA-256 changed.'
$liveStart=([datetimeoffset]$p.StartTime).ToUniversalTime()
Assert-True ($liveStart.UtcTicks -eq $expectedStart.UtcTicks) 'Live PID StartTime no longer matches the accepted process lifetime.'
$p.Refresh(); Assert-True (-not $p.HasExited) 'Process exited during pre-wire revalidation.'
Assert-True (((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()) -eq $expectedReceiptSha) 'Spawned-process receipt changed during pre-wire revalidation.'
Assert-True (((Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash.ToLowerInvariant()) -eq $expectedExeSha) 'Expected executable changed during pre-wire revalidation.'

$out=[IO.Path]::GetFullPath($ReceiptPath); $dir=Split-Path -Parent $out
if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Path $dir -Force|Out-Null }
$receipt=[ordered]@{
 schemaVersion=1; component='windows-mcp-pre-wire-process-identity-revalidation'; generatedAtUtc=[datetimeoffset]::UtcNow.ToString('o')
 sourceSpawnedProcessIdentity=[ordered]@{receiptPath=$source;receiptSha256=$expectedReceiptSha;stableAcrossRevalidation=$true}
 observedProcess=[ordered]@{pid=$targetProcessId;startTimeUtc=$liveStart.ToString('o');imagePath=$livePath;imageBackingFileSha256=$liveSha;stillRunningAtRevalidation=$true}
 acceptanceBoundary=[ordered]@{
  preWireProcessIdentityRevalidationAccepted=$true;samePidObserved=$true;sameProcessStartTimeObserved=$true;sameImagePathObserved=$true;sameImageBackingFileSha256Observed=$true;sourceReceiptStableAcrossRevalidation=$true;expectedExecutableStableAcrossRevalidation=$true;processStillRunningAtRevalidation=$true
  processLifetimeRaceFree=$false;createProcessExecutableBindingAtomicityProven=$false;exactLoadedImageBytesCryptographicallyProven=$false;processModulesEnumerationCompletenessProven=$false;dependentModuleTrustAccepted=$false;downstreamMcpServerPhysicalIdentityAccepted=$false;mcpProtocolRuntimeAccepted=$false;semanticToolAccepted=$false;windowsFinalStateAccepted=$false
 }
}
[IO.File]::WriteAllText($out,($receipt|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
$outSha=(Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject][ordered]@{receiptPath=$out;receiptSha256=$outSha;processId=$targetProcessId;processStartTimeUtc=$liveStart.ToString('o');imagePath=$livePath;imageBackingFileSha256=$liveSha;preWireProcessIdentityRevalidationAccepted=$true;processStillRunningAtRevalidation=$true;processLifetimeRaceFree=$false;downstreamMcpServerPhysicalIdentityAccepted=$false;semanticToolAccepted=$false;windowsFinalStateAccepted=$false}
