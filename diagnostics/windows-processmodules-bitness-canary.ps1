param(
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

if ($env:OS -ne 'Windows_NT') { throw 'Windows only.' }
Assert-True ([Environment]::Is64BitProcess) 'Canary requires a 64-bit verifier process.'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BraintrustBitnessNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWow64Process2(IntPtr processHandle, out ushort processMachine, out ushort nativeMachine);
}
'@

function Get-MachineName([uint16]$Machine) {
    switch ($Machine) {
        0x0000 { return 'UNKNOWN' }
        0x014c { return 'I386' }
        0x8664 { return 'AMD64' }
        0xAA64 { return 'ARM64' }
        default { return ('0x{0:x4}' -f $Machine) }
    }
}

function Get-ProcessMachineInfo([int]$ProcessId) {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    try {
        [uint16]$processMachine = 0
        [uint16]$nativeMachine = 0
        $ok = [BraintrustBitnessNative]::IsWow64Process2($process.Handle, [ref]$processMachine, [ref]$nativeMachine)
        if (-not $ok) { throw "IsWow64Process2 failed for PID $ProcessId; Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
        [uint16]$effective = if ($processMachine -eq 0) { $nativeMachine } else { $processMachine }
        return [pscustomobject][ordered]@{
            pid = $ProcessId
            processMachine = (Get-MachineName $processMachine)
            nativeMachine = (Get-MachineName $nativeMachine)
            effectiveMachine = (Get-MachineName $effective)
            processMachineRaw = [int]$processMachine
            nativeMachineRaw = [int]$nativeMachine
            effectiveMachineRaw = [int]$effective
        }
    } finally {
        $process.Dispose()
    }
}

function Get-RawModuleTelemetry([int]$ProcessId) {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    try {
        $modules = @($process.Modules)
        return [pscustomobject][ordered]@{
            moduleCount = $modules.Count
            paths = @($modules | ForEach-Object { try { [string]$_.FileName } catch { $null } } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    } finally {
        $process.Dispose()
    }
}

$currentMachine = Get-ProcessMachineInfo -ProcessId $PID
Assert-True ($currentMachine.effectiveMachine -in @('AMD64','ARM64')) 'Verifier machine must be AMD64 or ARM64.'

$sameExe = (Get-Process -Id $PID).Path
$x86Exe = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
Assert-True (Test-Path -LiteralPath $sameExe -PathType Leaf) 'Current 64-bit PowerShell executable missing.'
Assert-True (Test-Path -LiteralPath $x86Exe -PathType Leaf) '32-bit Windows PowerShell executable missing.'

$same = Start-Process -FilePath $sameExe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -PassThru -WindowStyle Hidden
$x86 = Start-Process -FilePath $x86Exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -PassThru -WindowStyle Hidden
try {
    Start-Sleep -Milliseconds 700
    $sameInfo = Get-ProcessMachineInfo -ProcessId $same.Id
    $x86Info = Get-ProcessMachineInfo -ProcessId $x86.Id

    Assert-True ($sameInfo.effectiveMachineRaw -eq $currentMachine.effectiveMachineRaw) 'Same-architecture child did not match verifier architecture.'
    Assert-True ($x86Info.effectiveMachine -eq 'I386') 'SysWOW64 child was not observed as I386.'
    Assert-True ($x86Info.effectiveMachineRaw -ne $currentMachine.effectiveMachineRaw) 'Cross-architecture child unexpectedly matched verifier architecture.'

    $sameModules = Get-RawModuleTelemetry -ProcessId $same.Id
    $x86Modules = Get-RawModuleTelemetry -ProcessId $x86.Id
    Assert-True ($sameModules.moduleCount -ge 1) 'Same-architecture Process.Modules returned no modules.'

    $receipt = [ordered]@{
        schemaVersion = 1
        component = 'public-windows-processmodules-bitness-canary'
        generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        powershell = [ordered]@{
            edition = [string]$PSVersionTable.PSEdition
            version = [string]$PSVersionTable.PSVersion
            is64BitProcess = [Environment]::Is64BitProcess
            is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
        }
        verifier = $currentMachine
        sameArchitectureChild = [ordered]@{
            machine = $sameInfo
            rawProcessModules = $sameModules
            processModulesArchitectureGateAccepted = $true
        }
        crossArchitectureChild = [ordered]@{
            machine = $x86Info
            rawProcessModules = $x86Modules
            processModulesArchitectureGateAccepted = $false
            rawProcessModulesCompletenessAccepted = $false
        }
        acceptanceBoundary = [ordered]@{
            sameArchitectureGateAccepted = $true
            crossArchitectureTargetRejected = $true
            callerBitnessOnlyGateSufficient = $false
            rawCrossArchitectureProcessModulesAcceptedAsComplete = $false
            processModulesCompletenessForSameArchitectureCryptographicallyProven = $false
            exactLoadedModuleBytesCryptographicallyProven = $false
            semanticMcpFunctionalityAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }

    $full = [IO.Path]::GetFullPath($OutputPath)
    $dir = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($full, ($receipt | ConvertTo-Json -Depth 10), $utf8)
    Write-Host "PROCESSMODULES_BITNESS_CANARY_PASS output=$full sameModules=$($sameModules.moduleCount) x86RawModules=$($x86Modules.moduleCount)"
} finally {
    foreach ($child in @($same,$x86)) {
        try { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } } catch {}
        try { $child.Dispose() } catch {}
    }
}
