param(
    [Parameter(Mandatory = $true)][string]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Assert-True ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) 'This canary requires native Windows.'
$runnerTemp = [System.IO.Path]::GetFullPath($env:RUNNER_TEMP)
$root = [System.IO.Path]::GetPathRoot($runnerTemp)
$drive = New-Object System.IO.DriveInfo($root)
Assert-True ($drive.DriveType -eq [System.IO.DriveType]::Fixed) 'RUNNER_TEMP must reside on a fixed local drive.'

$work = Join-Path $runnerTemp ('approval-reservation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$claim = Join-Path $work 'same-approval.claim'
$gate = Join-Path $work 'go.signal'
$worker = Join-Path $work 'claim-worker.ps1'
$resultA = Join-Path $work 'result-a.txt'
$resultB = Join-Path $work 'result-b.txt'

$workerBody = @'
param([string]$ClaimPath,[string]$GatePath,[string]$ResultPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$deadline=[datetime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath $GatePath -PathType Leaf)) {
  if ([datetime]::UtcNow -ge $deadline) { throw 'gate timeout' }
  Start-Sleep -Milliseconds 5
}
try {
  $stream = New-Object System.IO.FileStream($ClaimPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
  try {
    $bytes=[System.Text.Encoding]::UTF8.GetBytes(('winner:' + $PID))
    $stream.Write($bytes,0,$bytes.Length)
    $stream.Flush()
    Start-Sleep -Milliseconds 150
  } finally { $stream.Dispose() }
  [System.IO.File]::WriteAllText($ResultPath,'won',(New-Object System.Text.UTF8Encoding($false)))
} catch [System.IO.IOException] {
  [System.IO.File]::WriteAllText($ResultPath,'blocked',(New-Object System.Text.UTF8Encoding($false)))
}
'@
[System.IO.File]::WriteAllText($worker,$workerBody,(New-Object System.Text.UTF8Encoding($false)))

$hostExe = if ($PSVersionTable.PSEdition -eq 'Desktop') { Join-Path $PSHOME 'powershell.exe' } else { Join-Path $PSHOME 'pwsh.exe' }
Assert-True (Test-Path -LiteralPath $hostExe -PathType Leaf) 'Unable to resolve current PowerShell executable.'

$argsA = @('-NoLogo','-NoProfile','-NonInteractive','-File',$worker,'-ClaimPath',$claim,'-GatePath',$gate,'-ResultPath',$resultA)
$argsB = @('-NoLogo','-NoProfile','-NonInteractive','-File',$worker,'-ClaimPath',$claim,'-GatePath',$gate,'-ResultPath',$resultB)
$pA = Start-Process -FilePath $hostExe -ArgumentList $argsA -PassThru -WindowStyle Hidden
$pB = Start-Process -FilePath $hostExe -ArgumentList $argsB -PassThru -WindowStyle Hidden
[System.IO.File]::WriteAllText($gate,'go',(New-Object System.Text.UTF8Encoding($false)))
$pA.WaitForExit(30000) | Out-Null
$pB.WaitForExit(30000) | Out-Null
Assert-True ($pA.HasExited -and $pB.HasExited) 'Concurrent claim workers did not exit within the bound.'
Assert-True (Test-Path -LiteralPath $resultA -PathType Leaf) 'Worker A did not record a result.'
Assert-True (Test-Path -LiteralPath $resultB -PathType Leaf) 'Worker B did not record a result.'
$results = @((Get-Content -LiteralPath $resultA -Raw),(Get-Content -LiteralPath $resultB -Raw))
$wonCount = @($results | Where-Object { $_ -eq 'won' }).Count
$blockedCount = @($results | Where-Object { $_ -eq 'blocked' }).Count
Assert-True ($wonCount -eq 1 -and $blockedCount -eq 1) "Expected exactly one winner and one blocked claim; observed: $($results -join ',')."
Assert-True (Test-Path -LiteralPath $claim -PathType Leaf) 'Winning reservation claim did not persist after worker exit.'

$serialReplayBlocked = $false
try {
    $stream = New-Object System.IO.FileStream($claim,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    $stream.Dispose()
} catch [System.IO.IOException] {
    $serialReplayBlocked = $true
}
Assert-True $serialReplayBlocked 'Serial replay unexpectedly reacquired an existing reservation claim.'

$evidence = [ordered]@{
    schemaVersion = 1
    component = 'public-windows-mcp-approval-reservation-atomicity-canary'
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    runner = [ordered]@{
        osVersion = [System.Environment]::OSVersion.VersionString
        osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        processArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        powerShellEdition = $PSVersionTable.PSEdition
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        runnerImage = $env:ImageOS
        runnerArch = $env:RUNNER_ARCH
    }
    observation = [ordered]@{
        localFixedDriveObserved = $true
        concurrentCreateNewExactlyOneWinnerObserved = $true
        concurrentReplayBlockedObserved = $true
        serialReplayBlockedWhileClaimExistsObserved = $true
        claimPersistedAfterWinnerExitObserved = $true
    }
    acceptanceBoundary = [ordered]@{
        fileModeCreateNewAtomicNameAcquisitionAccepted = $true
        currentPowerShellNativeObservationAccepted = $true
        exactlyOnceToolSideEffectProven = $false
        crashRecoveryReplayAccepted = $false
        powerLossDurabilityAccepted = $false
        braintrustPrivateApprovalPipelineAccepted = $false
        approvalOriginAuthenticated = $false
        toolExecutionAuthorized = $false
        wireRequestSent = $false
        semanticToolAccepted = $false
        windowsFinalStateAccepted = $false
    }
}
$evidenceDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($EvidencePath))
if ($evidenceDir) { New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null }
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($EvidencePath),($evidence|ConvertTo-Json -Depth 20),(New-Object System.Text.UTF8Encoding($false)))
$evidence
