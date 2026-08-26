param(
    [Parameter(Mandatory = $true)][string]$ShellLabel,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class BraintrustPipeNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint GetFileType(IntPtr hFile);

    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetNamedPipeClientProcessId(IntPtr Pipe, out uint ClientProcessId);

    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetNamedPipeServerProcessId(IntPtr Pipe, out uint ServerProcessId);
}
"@

function Observe-PipeHandle {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][int]$ChildProcessId
    )

    if (-not ($Stream -is [System.IO.FileStream])) {
        throw "$Label stream is not a FileStream: $($Stream.GetType().FullName)"
    }

    $fileStream = [System.IO.FileStream]$Stream
    $handle = $fileStream.SafeFileHandle.DangerousGetHandle()
    $fileType = [BraintrustPipeNative]::GetFileType($handle)

    [uint32]$clientPid = 0
    $clientOk = [BraintrustPipeNative]::GetNamedPipeClientProcessId($handle, [ref]$clientPid)
    $clientError = if ($clientOk) { 0 } else { [Runtime.InteropServices.Marshal]::GetLastWin32Error() }

    [uint32]$serverPid = 0
    $serverOk = [BraintrustPipeNative]::GetNamedPipeServerProcessId($handle, [ref]$serverPid)
    $serverError = if ($serverOk) { 0 } else { [Runtime.InteropServices.Marshal]::GetLastWin32Error() }

    [ordered]@{
        label = $Label
        streamType = $Stream.GetType().FullName
        fileType = [int]$fileType
        fileTypePipe = ($fileType -eq 3)
        getNamedPipeClientProcessIdSucceeded = [bool]$clientOk
        namedPipeClientProcessId = [int64]$clientPid
        namedPipeClientProcessIdMatchesChild = ($clientOk -and ([int64]$clientPid -eq $ChildProcessId))
        namedPipeClientProcessIdMatchesParent = ($clientOk -and ([int64]$clientPid -eq $PID))
        getNamedPipeClientProcessIdLastError = [int]$clientError
        getNamedPipeServerProcessIdSucceeded = [bool]$serverOk
        namedPipeServerProcessId = [int64]$serverPid
        namedPipeServerProcessIdMatchesChild = ($serverOk -and ([int64]$serverPid -eq $ChildProcessId))
        namedPipeServerProcessIdMatchesParent = ($serverOk -and ([int64]$serverPid -eq $PID))
        getNamedPipeServerProcessIdLastError = [int]$serverError
    }
}

$childScript = Join-Path $env:RUNNER_TEMP ("stdio-peer-child-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
[System.IO.File]::WriteAllText($childScript, @'
$ErrorActionPreference = 'Stop'
$line = [Console]::In.ReadLine()
[Console]::Out.WriteLine('ack:' + $line)
[Console]::Out.Flush()
Start-Sleep -Milliseconds 500
'@, (New-Object System.Text.UTF8Encoding($false)))

$currentProcess = Get-Process -Id $PID
$childExe = $currentProcess.Path
if ([string]::IsNullOrWhiteSpace($childExe)) { throw 'Current shell executable path was not observable.' }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $childExe
$psi.Arguments = '-NoLogo -NoProfile -NonInteractive -File ' + $childScript
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$child = New-Object System.Diagnostics.Process
$child.StartInfo = $psi
if (-not $child.Start()) { throw 'Child process did not start.' }

try {
    $stdinObservation = Observe-PipeHandle -Stream $child.StandardInput.BaseStream -Label 'parent-write-to-child-stdin' -ChildProcessId $child.Id
    $stdoutObservation = Observe-PipeHandle -Stream $child.StandardOutput.BaseStream -Label 'parent-read-from-child-stdout' -ChildProcessId $child.Id

    $child.StandardInput.WriteLine('probe')
    $child.StandardInput.Flush()
    $ack = $child.StandardOutput.ReadLine()
    if ($ack -ne 'ack:probe') { throw "Unexpected child acknowledgement: '$ack'" }
    if (-not $child.WaitForExit(5000)) {
        try { $child.Kill() } catch {}
        throw 'Child process did not exit in time.'
    }

    $result = [ordered]@{
        schemaVersion = 1
        component = 'public-windows-stdio-anonymous-pipe-peer-observation'
        generatedAtUtc = [datetime]::UtcNow.ToString('o')
        diagnosticOnly = $true
        shellLabel = $ShellLabel
        powerShellEdition = $PSVersionTable.PSEdition
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        parentProcessId = [int]$PID
        childProcessId = [int]$child.Id
        childExecutablePath = $childExe
        osVersion = [Environment]::OSVersion.VersionString
        stdin = $stdinObservation
        stdout = $stdoutObservation
        acceptanceBoundary = [ordered]@{
            anonymousPipePeerPidApiAcceptedForProductionAuthority = $false
            targetStreamOwnershipByChildProcessProven = $false
            observationOnly = $true
        }
    }

    $outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDir = Split-Path -Parent $outputFullPath
    if ($outputDir) { New-Item -ItemType Directory -Force -Path $outputDir | Out-Null }
    [System.IO.File]::WriteAllText($outputFullPath, ($result | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
    $result
}
finally {
    if (-not $child.HasExited) { try { $child.Kill() } catch {} }
    $child.Dispose()
    Remove-Item -LiteralPath $childScript -Force -ErrorAction SilentlyContinue
}
