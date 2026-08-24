param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

if ($env:OS -ne 'Windows_NT') { throw 'Windows process-module architecture evidence only supports Windows.' }
Assert-True ($ProcessId -gt 0) 'ProcessId must be positive.'

if (-not ('BraintrustProcessArchitectureNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BraintrustProcessArchitectureNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWow64Process2(IntPtr processHandle, out ushort processMachine, out ushort nativeMachine);
}
'@
}

function Get-MachineName([uint16]$Machine) {
    switch ($Machine) {
        0x0000 { return 'UNKNOWN' }
        0x014c { return 'I386' }
        0x8664 { return 'AMD64' }
        0xAA64 { return 'ARM64' }
        default { return ('0x{0:x4}' -f $Machine) }
    }
}

function Get-MachineObservation([int]$Pid) {
    $process = Get-Process -Id $Pid -ErrorAction Stop
    try {
        [uint16]$processMachine = 0
        [uint16]$nativeMachine = 0
        $ok = [BraintrustProcessArchitectureNative]::IsWow64Process2($process.Handle, [ref]$processMachine, [ref]$nativeMachine)
        if (-not $ok) {
            throw "IsWow64Process2 failed for PID $Pid; Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        [uint16]$effective = if ($processMachine -eq 0) { $nativeMachine } else { $processMachine }
        return [pscustomobject][ordered]@{
            pid = $Pid
            processMachine = Get-MachineName $processMachine
            nativeMachine = Get-MachineName $nativeMachine
            effectiveMachine = Get-MachineName $effective
            processMachineRaw = [int]$processMachine
            nativeMachineRaw = [int]$nativeMachine
            effectiveMachineRaw = [int]$effective
        }
    } finally {
        $process.Dispose()
    }
}

$verifier = Get-MachineObservation -Pid $PID
$target = Get-MachineObservation -Pid $ProcessId
$match = ([int]$verifier.effectiveMachineRaw -eq [int]$target.effectiveMachineRaw)

$receipt = [ordered]@{
    schemaVersion = 1
    component = 'windows-processmodules-architecture-evidence'
    generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    verifier = $verifier
    target = $target
    acceptanceBoundary = [ordered]@{
        isWow64Process2ObservationAccepted = $true
        verifierAndTargetEffectiveMachineMatch = $match
        processModulesSameArchitecturePrerequisiteAccepted = $match
        crossArchitectureProcessModulesAcceptedAsComplete = $false
        processModulesEnumerationCompletenessProven = $false
        exactLoadedModuleBytesCryptographicallyProven = $false
        semanticMcpFunctionalityAccepted = $false
        windowsFinalStateAccepted = $false
    }
}

$full = [IO.Path]::GetFullPath($ReceiptPath)
$dir = Split-Path -Parent $full
if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($full, ($receipt | ConvertTo-Json -Depth 8), $utf8)
$sha = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()

if (-not $match) {
    throw "Process.Modules architecture gate rejected verifier=$($verifier.effectiveMachine) target=$($target.effectiveMachine); cross-architecture module enumeration is not accepted as complete. receipt=$full sha256=$sha"
}

[pscustomobject][ordered]@{
    receiptPath = $full
    receiptSha256 = $sha
    processModulesSameArchitecturePrerequisiteAccepted = $true
    processModulesEnumerationCompletenessProven = $false
    semanticMcpFunctionalityAccepted = $false
    windowsFinalStateAccepted = $false
}
