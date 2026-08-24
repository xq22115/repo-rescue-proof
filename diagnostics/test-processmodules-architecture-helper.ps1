param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$helper = Join-Path $PSScriptRoot 'Get-Windows-ProcessModulesArchitectureEvidence.ps1'
Assert-True (Test-Path -LiteralPath $helper -PathType Leaf) 'Architecture helper is missing.'
$fullOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $fullOutput -PathType Container)) { New-Item -ItemType Directory -Path $fullOutput -Force | Out-Null }

$sameExe = (Get-Process -Id $PID).Path
$x86Exe = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
Assert-True (Test-Path -LiteralPath $sameExe -PathType Leaf) 'Same-architecture PowerShell executable missing.'
Assert-True (Test-Path -LiteralPath $x86Exe -PathType Leaf) '32-bit Windows PowerShell executable missing.'

$same = Start-Process -FilePath $sameExe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -PassThru -WindowStyle Hidden
$x86 = Start-Process -FilePath $x86Exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -PassThru -WindowStyle Hidden
try {
    Start-Sleep -Milliseconds 700
    $sameReceipt = Join-Path $fullOutput 'same-architecture.json'
    $sameResult = & $helper -ProcessId $same.Id -ReceiptPath $sameReceipt
    Assert-True ([bool]$sameResult.processModulesSameArchitecturePrerequisiteAccepted) 'Same-architecture helper result was not accepted.'

    $crossReceipt = Join-Path $fullOutput 'cross-architecture.json'
    $crossRejected = $false
    try {
        & $helper -ProcessId $x86.Id -ReceiptPath $crossReceipt | Out-Null
    } catch {
        if ($_.Exception.Message -match 'cross-architecture module enumeration is not accepted as complete') { $crossRejected = $true } else { throw }
    }
    Assert-True $crossRejected 'Cross-architecture target was not rejected.'
    Assert-True (Test-Path -LiteralPath $crossReceipt -PathType Leaf) 'Cross-architecture rejection receipt was not written.'

    $cross = Get-Content -LiteralPath $crossReceipt -Raw | ConvertFrom-Json
    Assert-True ($cross.acceptanceBoundary.processModulesSameArchitecturePrerequisiteAccepted -eq $false) 'Cross-architecture receipt falsely accepted the same-architecture prerequisite.'
    Assert-True ($cross.acceptanceBoundary.crossArchitectureProcessModulesAcceptedAsComplete -eq $false) 'Cross-architecture receipt overclaimed Process.Modules completeness.'
    Assert-True ($cross.target.effectiveMachine -eq 'I386') 'Cross-architecture target was not observed as I386.'

    $summary = [ordered]@{
        schemaVersion = 1
        component = 'public-processmodules-architecture-helper-native-test'
        generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        powershellEdition = [string]$PSVersionTable.PSEdition
        powershellVersion = [string]$PSVersionTable.PSVersion
        sameArchitectureAccepted = $true
        crossArchitectureRejected = $true
        sameReceiptSha256 = (Get-FileHash -LiteralPath $sameReceipt -Algorithm SHA256).Hash.ToLowerInvariant()
        crossReceiptSha256 = (Get-FileHash -LiteralPath $crossReceipt -Algorithm SHA256).Hash.ToLowerInvariant()
        acceptanceBoundary = [ordered]@{
            exactHelperExecutedOnNativeWindows = $true
            sameArchitecturePrerequisiteAccepted = $true
            crossArchitectureTargetRejected = $true
            crossArchitectureProcessModulesAcceptedAsComplete = $false
            processModulesEnumerationCompletenessProven = $false
            windowsFinalStateAccepted = $false
        }
    }
    $summaryPath = Join-Path $fullOutput 'summary.json'
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 8), $utf8)
    Write-Host "PROCESSMODULES_ARCH_HELPER_NATIVE_PASS summary=$summaryPath"
} finally {
    foreach ($child in @($same,$x86)) {
        try { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } } catch {}
        try { $child.Dispose() } catch {}
    }
}
