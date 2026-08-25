Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$observedSut = Join-Path $scriptRoot 'Compare-Windows-Mcp-ObservedToolCatalog.ps1'
$canonicalHelper = Join-Path $scriptRoot 'ConvertTo-BraintrustCanonicalJson.ps1'
if (-not (Test-Path -LiteralPath $observedSut -PathType Leaf)) { throw 'Compare-Windows-Mcp-ObservedToolCatalog.ps1 was not found.' }
if (-not (Test-Path -LiteralPath $canonicalHelper -PathType Leaf)) { throw 'ConvertTo-BraintrustCanonicalJson.ps1 was not found.' }
. $canonicalHelper

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Write-Utf8NoBomJson([string]$Path, $Value, [int]$Depth = 20) {
    $json = $Value | ConvertTo-Json -Depth $Depth
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($Path), $json, $encoding)
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('braintrust-observed-catalog-encoding-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $tool = [ordered]@{
        name = 'alpha'
        description = 'Alpha tool.'
        inputSchema = [ordered]@{
            type = 'object'
            properties = [ordered]@{
                q = [ordered]@{ type = 'string' }
            }
        }
        outputSchema = [ordered]@{
            type = 'object'
            properties = [ordered]@{
                ok = [ordered]@{ type = 'boolean' }
            }
        }
    }

    $canonicalEntries = @(
        [ordered]@{
            name = 'alpha'
            description = 'Alpha tool.'
            inputSchema = ConvertTo-BraintrustCanonicalValue $tool.inputSchema
            outputSchema = ConvertTo-BraintrustCanonicalValue $tool.outputSchema
        }
    )
    $staticFingerprint = Get-BraintrustUtf8Sha256 (ConvertTo-BraintrustCanonicalJson $canonicalEntries)

    $staticReceiptPath = Join-Path $tempRoot 'static-receipt.json'
    $staticReceipt = [ordered]@{
        schemaVersion = 4
        component = 'windows-mcp-static-registration'
        staticRegistrationAccepted = $true
        staticToolCatalogAccepted = $true
        toolCatalogComparison = [ordered]@{
            comparisonMode = 'recursive-ordinal-object-key-sort-v1'
            staticCatalogCanonicalSha256 = $staticFingerprint
        }
    }
    Write-Utf8NoBomJson -Path $staticReceiptPath -Value $staticReceipt

    $observedPath = Join-Path $tempRoot 'tools-list.json'
    $observed = [ordered]@{
        jsonrpc = '2.0'
        id = 1
        result = [ordered]@{
            resultType = 'complete'
            tools = @($tool)
            ttlMs = 300000
            cacheScope = 'private'
        }
    }
    Write-Utf8NoBomJson -Path $observedPath -Value $observed

    $receiptPath = Join-Path $tempRoot 'observed-receipt.json'
    $receipt = & $observedSut -StaticRegistrationReceiptPath $staticReceiptPath -ObservedToolsListResponsePath $observedPath -ReceiptPath $receiptPath -ObservedAtUtc ([datetime]::UtcNow)

    Assert-True ([int]$receipt.schemaVersion -eq 4) 'Observed receipt schemaVersion changed unexpectedly.'
    Assert-True ([string]$receipt.component -eq 'windows-mcp-observed-tool-catalog') 'Observed receipt component is unexpected.'
    Assert-True ([bool]$receipt.observedToolCatalogAccepted) 'Observed receipt was not accepted.'

    $bytes = [System.IO.File]::ReadAllBytes($receiptPath)
    Assert-True ($bytes.Length -gt 0) 'Observed receipt is empty.'
    $hasUtf8Bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert-True (-not $hasUtf8Bom) 'Observed receipt must be UTF-8 without BOM.'

    $lastByte = $bytes[$bytes.Length - 1]
    Assert-True ($lastByte -ne 0x0D -and $lastByte -ne 0x0A) 'Observed receipt must not contain an implicit trailing CR/LF.'

    $roundTrip = ([System.Text.Encoding]::UTF8.GetString($bytes)) | ConvertFrom-Json
    Assert-True ([string]$roundTrip.component -eq 'windows-mcp-observed-tool-catalog') 'Observed receipt failed UTF-8 JSON round-trip.'
    Assert-True ([bool]$roundTrip.observedToolCatalogAccepted) 'Observed receipt acceptance did not survive raw-byte round-trip.'

    Write-Host 'Windows MCP observed tool-catalog receipt UTF-8 no-BOM contract: PASS'
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
