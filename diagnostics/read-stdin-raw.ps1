Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stdin = [Console]::OpenStandardInput()
$memory = New-Object System.IO.MemoryStream
$buffer = New-Object byte[] 4096
try {
    while (($read = $stdin.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $memory.Write($buffer, 0, $read)
    }
    $bytes = $memory.ToArray()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
    $prefixCount = [Math]::Min(8, $bytes.Length)
    $prefix = if ($prefixCount -gt 0) { (($bytes[0..($prefixCount - 1)] | ForEach-Object { $_.ToString('x2') }) -join '') } else { '' }
    $result = [ordered]@{
        byteLength = $bytes.Length
        sha256 = $digest
        base64 = [Convert]::ToBase64String($bytes)
        hexPrefix = $prefix
    }
    [Console]::Out.Write(($result | ConvertTo-Json -Compress))
} finally {
    $memory.Dispose()
    $stdin.Dispose()
}
