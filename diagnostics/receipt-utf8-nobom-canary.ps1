param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$json = '{"accepted":false,"component":"receipt-encoding-canary","schemaVersion":1}'
$expectedFixedSha256 = '8493634f1f8df2b9d623e488a25059b5afbe054ad360f7884fa3a16ed3bf65c4'
$legacyPath = Join-Path $OutputDirectory 'legacy-set-content-utf8.json'
$fixedPath = Join-Path $OutputDirectory 'explicit-utf8-no-bom.json'

# Historical/edition-dependent spelling retained only for the counterfactual.
$json | Set-Content -LiteralPath $legacyPath -Encoding UTF8

# Exact production candidate primitive: explicit UTF-8 without BOM.
$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
[System.IO.File]::WriteAllText($fixedPath, $json, $utf8NoBom)

function Get-Bytes([string]$Path) {
    return [System.IO.File]::ReadAllBytes($Path)
}
function Test-Utf8Bom([byte[]]$Bytes) {
    return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
}
function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$legacyBytes = Get-Bytes $legacyPath
$fixedBytes = Get-Bytes $fixedPath
$legacyBom = Test-Utf8Bom $legacyBytes
$fixedBom = Test-Utf8Bom $fixedBytes
$fixedSha = Get-Sha256 $fixedPath

if ($fixedBom) { throw 'Explicit UTF8Encoding(false) output unexpectedly contains a UTF-8 BOM.' }
if ($fixedBytes.Length -ne 74) { throw "Explicit UTF-8 output byte length drifted: $($fixedBytes.Length)." }
if ($fixedSha -ne $expectedFixedSha256) { throw "Explicit UTF-8 output SHA-256 drifted: $fixedSha." }
if ($fixedBytes -contains 0x0D -or $fixedBytes -contains 0x0A) { throw 'Explicit writer unexpectedly appended a newline.' }

if ($PSVersionTable.PSEdition -eq 'Desktop') {
    if (-not $legacyBom) { throw 'Windows PowerShell 5.1 Set-Content -Encoding UTF8 did not exhibit the expected BOM counterfactual.' }
} elseif ($PSVersionTable.PSEdition -eq 'Core') {
    if ($legacyBom) { throw 'PowerShell Core Set-Content -Encoding UTF8 unexpectedly emitted a BOM.' }
} else {
    throw "Unexpected PowerShell edition: $($PSVersionTable.PSEdition)"
}

$receipt = [ordered]@{
    schemaVersion = 1
    component = 'public-receipt-utf8-nobom-canary'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    osVersion = [Environment]::OSVersion.VersionString
    processArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    powerShellEdition = [string]$PSVersionTable.PSEdition
    powerShellVersion = [string]$PSVersionTable.PSVersion
    legacySetContentUtf8 = [ordered]@{
        byteLength = $legacyBytes.Length
        sha256 = Get-Sha256 $legacyPath
        bomObserved = $legacyBom
    }
    explicitUtf8NoBom = [ordered]@{
        byteLength = $fixedBytes.Length
        sha256 = $fixedSha
        expectedSha256 = $expectedFixedSha256
        bomObserved = $fixedBom
        newlineAppended = $false
    }
    acceptanceBoundary = [ordered]@{
        editionDependentSetContentUtf8BehaviorObserved = $true
        explicitUtf8NoBomWriterAccepted = $true
        privateBraintrustProductionReceiptAccepted = $false
        odrProvisioningSemanticStateAccepted = $false
        mcpRuntimeAccepted = $false
        windowsFinalStateAccepted = $false
    }
}

$receiptPath = Join-Path $OutputDirectory 'receipt-encoding-canary.json'
[System.IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 8), $utf8NoBom)
Write-Output "Receipt encoding canary: PASS ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion))"
