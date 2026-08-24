param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][string]$ExpectedExecutablePath,
    [Parameter(Mandatory = $true)][string]$ExpectedExecutableSha256,
    [string]$TrustedInstallRoot,
    [string]$OutputReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-Sha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$FieldPath
    )
    if ($Value -notmatch '^[0-9a-fA-F]{64}$') {
        throw "$FieldPath must be a 64-hex SHA-256."
    }
    return $Value.ToLowerInvariant()
}

function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $digest = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$RootPath
    )
    $candidate = [System.IO.Path]::GetFullPath($CandidatePath)
    $root = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\') + '\'
    return $candidate.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-MachineName {
    param([Parameter(Mandatory = $true)][uint16]$Machine)
    switch ($Machine) {
        0x0000 { return 'UNKNOWN' }
        0x014c { return 'I386' }
        0x8664 { return 'AMD64' }
        0xAA64 { return 'ARM64' }
        default { return ('0x{0:x4}' -f $Machine) }
    }
}

function Get-ProcessMachineObservation {
    param([Parameter(Mandatory = $true)][int]$TargetProcessId)

    if (-not ('BraintrustProcessModuleInventoryArchitectureNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BraintrustProcessModuleInventoryArchitectureNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWow64Process2(IntPtr processHandle, out ushort processMachine, out ushort nativeMachine);
}
'@
    }

    $targetProcess = Get-Process -Id $TargetProcessId -ErrorAction Stop
    try {
        [uint16]$processMachine = 0
        [uint16]$nativeMachine = 0
        $ok = [BraintrustProcessModuleInventoryArchitectureNative]::IsWow64Process2(
            $targetProcess.Handle,
            [ref]$processMachine,
            [ref]$nativeMachine
        )
        if (-not $ok) {
            throw "IsWow64Process2 failed for PID $TargetProcessId; Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        [uint16]$effectiveMachine = if ($processMachine -eq 0) { $nativeMachine } else { $processMachine }
        return [pscustomobject][ordered]@{
            pid = $TargetProcessId
            processMachine = Get-MachineName -Machine $processMachine
            nativeMachine = Get-MachineName -Machine $nativeMachine
            effectiveMachine = Get-MachineName -Machine $effectiveMachine
            processMachineRaw = [int]$processMachine
            nativeMachineRaw = [int]$nativeMachine
            effectiveMachineRaw = [int]$effectiveMachine
        }
    } finally {
        $targetProcess.Dispose()
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Get-Windows-ProcessModuleInventory.ps1 only supports Windows.'
}
if ($ProcessId -le 0) {
    throw 'ProcessId must be a positive integer.'
}
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    throw 'A 32-bit PowerShell process on 64-bit Windows cannot provide a complete 64-bit Process.Modules inventory; fail closed.'
}

$expectedPath = [System.IO.Path]::GetFullPath($ExpectedExecutablePath)
if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
    throw "Expected executable does not exist: $expectedPath"
}
$expectedSha = Assert-Sha256 -Value $ExpectedExecutableSha256 -FieldPath 'ExpectedExecutableSha256'
$currentExpectedSha = (Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($currentExpectedSha -ne $expectedSha) {
    throw 'Expected executable SHA-256 no longer matches current bytes.'
}

$process = Get-Process -Id $ProcessId -ErrorAction Stop
$processPath = $null
try { $processPath = [string]$process.Path } catch { }
if ([string]::IsNullOrWhiteSpace($processPath)) {
    try { $processPath = [string]$process.MainModule.FileName } catch { }
}
if ([string]::IsNullOrWhiteSpace($processPath)) {
    throw "Unable to read process image path for PID $ProcessId."
}
$processPath = [System.IO.Path]::GetFullPath($processPath)
if (-not $processPath.Equals($expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Process image path does not match expected executable. expected='$expectedPath' actual='$processPath'"
}
$processSha = (Get-FileHash -LiteralPath $processPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($processSha -ne $expectedSha) {
    throw 'Process image file SHA-256 does not match expected executable SHA-256.'
}

# System.Diagnostics.Process.Modules has a known Windows cross-bitness incompleteness surface:
# a 64-bit caller can omit 32-bit modules of a 32-bit target. Require the verifier and target
# to report the same effective machine through IsWow64Process2 before Process.Modules is touched.
$verifierMachine = Get-ProcessMachineObservation -TargetProcessId $PID
$targetMachine = Get-ProcessMachineObservation -TargetProcessId $ProcessId
$processModulesArchitectureMatch = (
    [int]$verifierMachine.effectiveMachineRaw -eq [int]$targetMachine.effectiveMachineRaw
)
if (-not $processModulesArchitectureMatch) {
    throw "Process.Modules architecture gate rejected verifier=$($verifierMachine.effectiveMachine) target=$($targetMachine.effectiveMachine); cross-architecture module enumeration is not accepted as complete."
}

$trustedRoot = $null
if (-not [string]::IsNullOrWhiteSpace($TrustedInstallRoot)) {
    $trustedRoot = [System.IO.Path]::GetFullPath($TrustedInstallRoot)
}
$windowsRoot = if ($env:SystemRoot) { [System.IO.Path]::GetFullPath($env:SystemRoot) } else { $null }

try {
    $modules = @($process.Modules)
} catch {
    throw "Unable to enumerate Process.Modules for PID $ProcessId: $($_.Exception.Message)"
}
if ($modules.Count -lt 1) {
    throw "Process.Modules returned no modules for PID $ProcessId."
}

$seen = @{}
$records = New-Object System.Collections.Generic.List[object]
$mainModuleMatches = 0
foreach ($module in $modules) {
    if ($null -eq $module) {
        throw 'Process.Modules contained a null entry.'
    }
    $modulePath = $null
    try { $modulePath = [string]$module.FileName } catch { }
    if ([string]::IsNullOrWhiteSpace($modulePath)) {
        throw "A loaded module for PID $ProcessId did not expose FileName."
    }
    $modulePath = [System.IO.Path]::GetFullPath($modulePath)
    $key = $modulePath.ToLowerInvariant()
    if ($seen.ContainsKey($key)) {
        throw "Duplicate canonical module path in Process.Modules: $modulePath"
    }
    $seen[$key] = $true
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Loaded module path is not a readable file at snapshot time: $modulePath"
    }
    $moduleSha = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($moduleSha -notmatch '^[0-9a-f]{64}$') {
        throw "Loaded module SHA-256 format is invalid: $modulePath"
    }

    $isMain = $modulePath.Equals($expectedPath, [System.StringComparison]::OrdinalIgnoreCase)
    if ($isMain) { $mainModuleMatches++ }
    $classification = if ($isMain) {
        'expected-main-executable'
    } elseif ($trustedRoot -and (Test-PathWithinRoot -CandidatePath $modulePath -RootPath $trustedRoot)) {
        'trusted-install-root'
    } elseif ($windowsRoot -and (Test-PathWithinRoot -CandidatePath $modulePath -RootPath $windowsRoot)) {
        'windows-root'
    } else {
        'other'
    }

    $moduleName = $null
    try { $moduleName = [string]$module.ModuleName } catch { }
    $fileVersion = $null
    try { $fileVersion = [string]$module.FileVersionInfo.FileVersion } catch { }

    $records.Add([pscustomobject][ordered]@{
        moduleName = $moduleName
        path = $modulePath
        sha256 = $moduleSha
        fileVersion = $fileVersion
        classification = $classification
        isMainExecutable = $isMain
    }) | Out-Null
}
if ($mainModuleMatches -ne 1) {
    throw "Expected executable must appear exactly once in Process.Modules; actual=$mainModuleMatches"
}

$sortedRecords = @($records | Sort-Object @{ Expression = { $_.path.ToLowerInvariant() } }, @{ Expression = { $_.sha256 } })
$fingerprintMaterial = (($sortedRecords | ForEach-Object { "$($_.path.ToLowerInvariant())|$($_.sha256)" }) -join "`n")
$moduleSetFingerprint = Get-Sha256Text -Text $fingerprintMaterial

$receipt = [ordered]@{
    schemaVersion = 2
    component = 'windows-process-module-inventory'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    verifier = [ordered]@{
        processBitness = if ([Environment]::Is64BitProcess) { 64 } else { 32 }
        operatingSystemBitness = if ([Environment]::Is64BitOperatingSystem) { 64 } else { 32 }
        enumerationMethod = 'System.Diagnostics.Process.Modules'
        architectureObservationMethod = 'IsWow64Process2'
        effectiveMachine = [string]$verifierMachine.effectiveMachine
        effectiveMachineRaw = [int]$verifierMachine.effectiveMachineRaw
    }
    process = [ordered]@{
        pid = $ProcessId
        startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
        imagePath = $processPath
        imageFileSha256 = $processSha
        effectiveMachine = [string]$targetMachine.effectiveMachine
        effectiveMachineRaw = [int]$targetMachine.effectiveMachineRaw
    }
    processModulesArchitecture = [ordered]@{
        verifierEffectiveMachine = [string]$verifierMachine.effectiveMachine
        verifierEffectiveMachineRaw = [int]$verifierMachine.effectiveMachineRaw
        targetEffectiveMachine = [string]$targetMachine.effectiveMachine
        targetEffectiveMachineRaw = [int]$targetMachine.effectiveMachineRaw
        sameArchitecturePrerequisiteAccepted = $true
        enumerationCompletenessProven = $false
    }
    moduleInventory = [ordered]@{
        moduleCount = $sortedRecords.Count
        moduleSetFingerprintSha256 = $moduleSetFingerprint
        modules = $sortedRecords
    }
    acceptanceBoundary = [ordered]@{
        processImageIdentityAccepted = $true
        processModulesSameArchitecturePrerequisiteAccepted = $true
        processModulesEnumerationCompletenessProven = $false
        moduleEnumerationAccepted = $true
        allModulePathsCanonicalized = $true
        allModuleFilesPresentAtSnapshot = $true
        allModuleFileHashesRead = $true
        mainExecutablePresentExactlyOnce = $true
        moduleInventorySnapshotAccepted = $true
        dependentModuleTrustAccepted = $false
        dllSearchPolicyAccepted = $false
        dynamicModulesLoadedAfterSnapshotCovered = $false
        moduleSetStableAcrossMultipleSnapshots = $false
        exactLoadedModuleBytesCryptographicallyProven = $false
        platformBackedAttestation = $false
        semanticMcpFunctionalityAccepted = $false
        windowsFinalStateAccepted = $false
    }
}

if (-not [string]::IsNullOrWhiteSpace($OutputReceiptPath)) {
    $outputFullPath = [System.IO.Path]::GetFullPath($OutputReceiptPath)
    $outputDir = Split-Path -Parent $outputFullPath
    if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    $receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outputFullPath -Encoding UTF8
    $receiptSha = (Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [pscustomobject][ordered]@{
        receiptPath = $outputFullPath
        receiptSha256 = $receiptSha
        processModulesSameArchitecturePrerequisiteAccepted = $true
        processModulesEnumerationCompletenessProven = $false
        moduleInventorySnapshotAccepted = $true
        moduleSetFingerprintSha256 = $moduleSetFingerprint
        moduleCount = $sortedRecords.Count
        dependentModuleTrustAccepted = $false
        dynamicModulesLoadedAfterSnapshotCovered = $false
        semanticMcpFunctionalityAccepted = $false
        windowsFinalStateAccepted = $false
    }
} else {
    [pscustomobject]$receipt
}
