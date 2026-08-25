Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$payload = '{"schemaVersion":3,"component":"openai-tunnel-client","powershellTransportBroker":{"powershellEdition":"Core","powershellVersion":"7.6.5"},"installedAtUtc":"2026-08-25T12:00:00.0000000Z"}'
$oldPath = Join-Path $env:RUNNER_TEMP 'main-install-receipt-old.json'
$newPath = Join-Path $env:RUNNER_TEMP 'main-install-receipt-new.json'

$payload | Set-Content -LiteralPath $oldPath -Encoding UTF8
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($newPath, $payload, $utf8NoBom)

function Get-Sha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Has-Utf8Bom([byte[]]$Bytes) {
    return $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
}

function Has-TrailingCrLf([byte[]]$Bytes) {
    return $Bytes.Length -ge 2 -and $Bytes[$Bytes.Length - 2] -eq 0x0D -and $Bytes[$Bytes.Length - 1] -eq 0x0A
}

function Has-TrailingLf([byte[]]$Bytes) {
    return $Bytes.Length -ge 1 -and $Bytes[$Bytes.Length - 1] -eq 0x0A
}

$oldBytes = [System.IO.File]::ReadAllBytes($oldPath)
$newBytes = [System.IO.File]::ReadAllBytes($newPath)
$expectedBytes = $utf8NoBom.GetBytes($payload)

$oldSha = Get-Sha256 $oldBytes
$newSha = Get-Sha256 $newBytes
$expectedSha = Get-Sha256 $expectedBytes
$newExact = [System.Linq.Enumerable]::SequenceEqual([byte[]]$newBytes, [byte[]]$expectedBytes)

$result = [ordered]@{
    os = [System.Environment]::OSVersion.VersionString
    psEdition = [string]$PSVersionTable.PSEdition
    psVersion = [string]$PSVersionTable.PSVersion
    oldByteLength = $oldBytes.Length
    oldSha256 = $oldSha
    oldHasUtf8Bom = (Has-Utf8Bom $oldBytes)
    oldHasTrailingCrLf = (Has-TrailingCrLf $oldBytes)
    oldHasTrailingLf = (Has-TrailingLf $oldBytes)
    newByteLength = $newBytes.Length
    newSha256 = $newSha
    newHasUtf8Bom = (Has-Utf8Bom $newBytes)
    newHasTrailingCrLf = (Has-TrailingCrLf $newBytes)
    newHasTrailingLf = (Has-TrailingLf $newBytes)
    expectedSha256 = $expectedSha
    newBytesExactlyMatchExplicitUtf8NoBom = $newExact
}

Write-Host ('MAIN_INSTALL_RECEIPT_ENCODING_RESULT=' + ($result | ConvertTo-Json -Compress))
if (-not $newExact) { throw 'Explicit UTF-8 no-BOM writer did not produce the expected bytes.' }
if (Has-Utf8Bom $newBytes) { throw 'Explicit UTF-8 no-BOM writer unexpectedly emitted a BOM.' }
if (Has-TrailingLf $newBytes) { throw 'Explicit WriteAllText writer unexpectedly appended a newline.' }
