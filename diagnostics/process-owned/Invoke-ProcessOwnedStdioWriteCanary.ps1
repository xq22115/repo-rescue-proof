param([Parameter(Mandatory=$true)][string]$ShellLabel,[Parameter(Mandatory=$true)][string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapper=Join-Path $root 'Invoke-Windows-Mcp-ProcessOwnedNearWireStdioFrameWriteAttempt.ps1'
function Sha([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function Image([Diagnostics.Process]$p){$x=$null;try{$x=$p.Path}catch{};if([string]::IsNullOrWhiteSpace($x)){$x=$p.MainModule.FileName};[IO.Path]::GetFullPath($x)}
function Start-ProbeChild([string]$tag){
  $childScript=Join-Path $env:RUNNER_TEMP ("process-owned-child-$tag-"+[guid]::NewGuid().ToString('N')+'.ps1')
  [IO.File]::WriteAllText($childScript,"`$line=[Console]::In.ReadLine()`n[Console]::Out.WriteLine('ack:'+`$line)`n[Console]::Out.Flush()`nStart-Sleep -Seconds 4`n",(New-Object Text.UTF8Encoding($false)))
  $exe=Image (Get-Process -Id $PID)
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=$exe; $psi.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+$childScript+'"'; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
  $psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
  $p=New-Object Diagnostics.Process; $p.StartInfo=$psi; if(-not $p.Start()){throw 'child start failed'}
  [pscustomobject]@{Process=$p;Script=$childScript}
}
function Write-Json([string]$p,[object]$o){$d=Split-Path -Parent $p;if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null};[IO.File]::WriteAllText($p,($o|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))}
$work=Join-Path $env:RUNNER_TEMP ('process-owned-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $work|Out-Null
$primary=Start-ProbeChild 'primary'; $sibling=$null
try{
  Start-Sleep -Milliseconds 150
  $p=$primary.Process; $img=Image $p; $imgSha=Sha $img; $st=([datetimeoffset]$p.StartTime).ToUniversalTime().ToString('o')
  $spawn=Join-Path $work 'spawn.json'; Write-Json $spawn ([ordered]@{component='diagnostic-spawn';pid=[int]$p.Id;startTimeUtc=$st;imagePath=$img;imageSha256=$imgSha}); $spawnSha=Sha $spawn
  $session=Join-Path $work 'session.json'; Write-Json $session ([ordered]@{schemaVersion=1;component='windows-mcp-stdio-session-affinity-binding';expectedProtocolVersion='2026-07-28';acceptanceBoundary=[ordered]@{stdioCatalogProcessAffinityAccepted=$true;targetStreamOwnershipByBoundProcessProven=$false;sameTransportConnectionObjectProven=$false};processAffinity=[ordered]@{processId=[int]$p.Id;processStartTimeUtc=$st;imagePath=$img;imageBackingFileSha256=$imgSha};inputEvidence=[ordered]@{targetSpawnedProcessIdentityReceiptPath=$spawn;targetSpawnedProcessIdentityReceiptSha256=$spawnSha}}); $sessionSha=Sha $session
  $near=Join-Path $work 'near.json'; Write-Json $near ([ordered]@{diagnosticOnly=$true});$nearSha=Sha $near
  $frame=Join-Path $work 'frame.json'; Write-Json $frame ([ordered]@{diagnosticOnly=$true});$frameSha=Sha $frame
  $cw=Join-Path $work 'child-write.json';$nw=Join-Path $work 'near-write.json';$wr=Join-Path $work 'wrapper.json'
  & $wrapper -TargetProcess $p -StdioSessionAffinityReceiptPath $session -ExpectedStdioSessionAffinityReceiptSha256 $sessionSha -NearWireRevalidationReceiptPath $near -ExpectedNearWireRevalidationReceiptSha256 $nearSha -FramePlanReceiptPath $frame -ExpectedFramePlanReceiptSha256 $frameSha -ChildWriteAttemptReceiptPath $cw -NearWireWriteReceiptPath $nw -ReceiptPath $wr | Out-Null
  $ack=$p.StandardOutput.ReadLine(); if($ack -ne 'ack:braintrust-process-owned-probe'){throw "unexpected primary ack: $ack"}
  $wrapperReceipt=(Get-Content -Raw $wr|ConvertFrom-Json); if(-not $wrapperReceipt.acceptanceBoundary.processOwnedStreamConstructionAccepted){throw 'primary process-owned acceptance missing'}
  $sibling=Start-ProbeChild 'sibling'; Start-Sleep -Milliseconds 150
  $sw=Join-Path $work 'sibling-child-write.json';$sn=Join-Path $work 'sibling-near-write.json';$sr=Join-Path $work 'sibling-wrapper.json'
  $rejected=$false;$reason=''
  try{& $wrapper -TargetProcess $sibling.Process -StdioSessionAffinityReceiptPath $session -ExpectedStdioSessionAffinityReceiptSha256 $sessionSha -NearWireRevalidationReceiptPath $near -ExpectedNearWireRevalidationReceiptSha256 $nearSha -FramePlanReceiptPath $frame -ExpectedFramePlanReceiptSha256 $frameSha -ChildWriteAttemptReceiptPath $sw -NearWireWriteReceiptPath $sn -ReceiptPath $sr | Out-Null}catch{$rejected=$true;$reason=$_.Exception.Message}
  if(-not $rejected){throw 'same-executable sibling process was not rejected'}
  if(Test-Path $sw){throw 'sibling reached diagnostic sender unexpectedly'}
  $out=[ordered]@{schemaVersion=1;component='public-windows-process-owned-stdio-write-canary';diagnosticOnly=$true;shellLabel=$ShellLabel;powerShellEdition=$PSVersionTable.PSEdition;powerShellVersion=$PSVersionTable.PSVersion.ToString();osVersion=[Environment]::OSVersion.VersionString;productionWrapperGitBlobExpected='c77fcb64868f3ad9d7d927caea20512fb734f4d4';strictJsonHelperGitBlobExpected='4bc29ae306b613aafcc37c4bc63e54e321a38eb2';primary=[ordered]@{processId=[int]$p.Id;imagePath=$img;imageSha256=$imgSha;processOwnedWrapperAccepted=$true;childAcknowledgedExactProbe=$true};sibling=[ordered]@{processId=[int]$sibling.Process.Id;sameExecutablePath=([string]::Equals((Image $sibling.Process),$img,[StringComparison]::OrdinalIgnoreCase));sameExecutableSha256=((Sha (Image $sibling.Process)) -eq $imgSha);rejectedBeforeSender=$true;rejectionReason=$reason};acceptanceBoundary=[ordered]@{exactProductionWrapperBytesExercised=$true;focusedStrictJsonHelperExactPrivateBytes=$true;nearWireSenderIsDiagnosticStub=$true;processOwnedStreamConstructionNativeAccepted=$true;sameExecutableSiblingProcessRejected=$true;fullProductionNearWireChainAccepted=$false;kernelPipePeerIdentityProven=$false;deliveryOutcomeKnown=$false;semanticToolAccepted=$false}}
  Write-Json ([IO.Path]::GetFullPath($OutputPath)) $out; $out
} finally {
  foreach($c in @($primary,$sibling)){if($null-ne$c){try{if(-not $c.Process.HasExited){$c.Process.Kill()}}catch{};try{$c.Process.Dispose()}catch{};try{Remove-Item -LiteralPath $c.Script -Force -ErrorAction SilentlyContinue}catch{}}}
}
