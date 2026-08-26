param(
    [Parameter(Mandatory=$true)][string]$NearWireRevalidationReceiptPath,
    [Parameter(Mandatory=$true)][string]$ExpectedNearWireRevalidationReceiptSha256,
    [Parameter(Mandatory=$true)][string]$FramePlanReceiptPath,
    [Parameter(Mandatory=$true)][string]$ExpectedFramePlanReceiptSha256,
    [Parameter(Mandatory=$true)][System.IO.Stream]$TargetStream,
    [Parameter(Mandatory=$true)][string]$ChildWriteAttemptReceiptPath,
    [Parameter(Mandatory=$true)][string]$ReceiptPath,
    [int]$WriteTimeoutMs=5000,
    [string]$ExpectedProtocolVersion='2026-07-28',
    [string]$Transport='stdio'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $TargetStream.CanWrite){throw 'Diagnostic target stream is not writable.'}
$bytes=[Text.Encoding]::UTF8.GetBytes("braintrust-process-owned-probe`n")
$TargetStream.Write($bytes,0,$bytes.Length)
$TargetStream.Flush()
foreach($p in @($ChildWriteAttemptReceiptPath,$ReceiptPath)){
  $full=[IO.Path]::GetFullPath($p); $d=Split-Path -Parent $full; if($d){New-Item -ItemType Directory -Path $d -Force|Out-Null}
  [IO.File]::WriteAllText($full,'{"component":"diagnostic-near-wire-stub","wireRequestSent":false}',(New-Object Text.UTF8Encoding($false)))
}
[pscustomobject]@{diagnosticOnly=$true; actualTransportWriteObserved=$true; wireRequestSent=$false}
