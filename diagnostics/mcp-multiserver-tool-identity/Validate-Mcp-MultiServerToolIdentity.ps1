param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-JsonObject([object]$Value, [string]$Path) {
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
        throw "$Path must be a JSON object."
    }
    return $Value
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Path) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Path.$Name is required." }
    # Preserve singleton JSON arrays as arrays across Windows PowerShell 5.1 and
    # PowerShell 7. Ordinary function output enumerates arrays into the pipeline,
    # which can collapse a one-element array into its sole PSCustomObject.
    Write-Output -NoEnumerate $property.Value
    return
}

function Get-RequiredString([object]$Object, [string]$Name, [string]$Path) {
    $value = Get-RequiredProperty $Object $Name $Path
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) {
        throw "$Path.$Name must be a non-empty JSON string."
    }
    return [string]$value
}

function Get-RequiredInteger([object]$Object, [string]$Name, [string]$Path) {
    $value = Get-RequiredProperty $Object $Name $Path
    if ($value -isnot [int] -and $value -isnot [long]) {
        throw "$Path.$Name must be a JSON integer."
    }
    return [long]$value
}

function Get-RequiredArray([object]$Object, [string]$Name, [string]$Path) {
    $value = Get-RequiredProperty $Object $Name $Path
    if ($null -eq $value -or $value -isnot [System.Array]) {
        throw "$Path.$Name must be a JSON array."
    }
    return @($value)
}

function Get-Utf8Sha256([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "ManifestPath not found: $ManifestPath"
}

$manifest = (Get-Content -LiteralPath $ManifestPath -Raw) | ConvertFrom-Json
$manifest = Assert-JsonObject $manifest 'manifest'
$schemaVersion = Get-RequiredInteger $manifest 'schemaVersion' 'manifest'
if ($schemaVersion -ne 1) { throw "manifest.schemaVersion must be 1." }
$servers = @(Get-RequiredArray $manifest 'servers' 'manifest')
if ($servers.Count -lt 1) { throw 'manifest.servers must contain at least one server.' }

$serverIdentities = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$routeKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$exposedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$caseInsensitiveExposed = @{}
$routeRecords = @()
$recommendedRawToolNameViolations = @()
$caseInsensitiveCollisionPairs = @()

$serverIndex = 0
foreach ($serverValue in $servers) {
    $serverPath = "manifest.servers[$serverIndex]"
    $server = Assert-JsonObject $serverValue $serverPath
    $serverIdentitySha256 = (Get-RequiredString $server 'serverIdentitySha256' $serverPath).ToLowerInvariant()
    if ($serverIdentitySha256 -notmatch '^[0-9a-f]{64}$') {
        throw "$serverPath.serverIdentitySha256 must be 64 lowercase/uppercase hex characters."
    }
    if (-not $serverIdentities.Add($serverIdentitySha256)) {
        throw "Duplicate serverIdentitySha256 is not allowed: $serverIdentitySha256"
    }
    $displayServerName = Get-RequiredString $server 'displayServerName' $serverPath
    $tools = @(Get-RequiredArray $server 'tools' $serverPath)
    if ($tools.Count -lt 1) { throw "$serverPath.tools must contain at least one tool." }

    $toolIndex = 0
    foreach ($toolValue in $tools) {
        $toolPath = "$serverPath.tools[$toolIndex]"
        $tool = Assert-JsonObject $toolValue $toolPath
        $toolName = Get-RequiredString $tool 'name' $toolPath
        $exposedName = Get-RequiredString $tool 'exposedName' $toolPath

        if ($exposedName -notmatch '^[A-Za-z0-9_.-]{1,128}$') {
            throw "$toolPath.exposedName violates the local safe model-visible tool-name policy."
        }
        if ($toolName -notmatch '^[A-Za-z0-9_.-]{1,128}$') {
            $recommendedRawToolNameViolations += [ordered]@{
                serverIdentitySha256 = $serverIdentitySha256
                toolName = $toolName
            }
        }

        # A structured tuple is the routing identity. Neither serverInfo.name nor
        # tool name alone is globally unique across an aggregated multi-server client.
        # Use an explicit separator character rather than the PowerShell 7-only
        # `u{...} escape syntax so the fingerprint is identical on PS 5.1 and 7.
        $routeTuple = $serverIdentitySha256 + [char]31 + $toolName
        if (-not $routeKeys.Add($routeTuple)) {
            throw "Duplicate structured route identity: server=$serverIdentitySha256 tool=$toolName"
        }
        if (-not $exposedNames.Add($exposedName)) {
            throw "Duplicate model-visible exposedName is not allowed: $exposedName"
        }

        $lower = $exposedName.ToLowerInvariant()
        if ($caseInsensitiveExposed.ContainsKey($lower)) {
            $previous = [string]$caseInsensitiveExposed[$lower]
            if ($previous -cne $exposedName) {
                $caseInsensitiveCollisionPairs += [ordered]@{
                    first = $previous
                    second = $exposedName
                }
            }
        }
        else {
            $caseInsensitiveExposed[$lower] = $exposedName
        }

        $routeRecords += [ordered]@{
            serverIdentitySha256 = $serverIdentitySha256
            displayServerName = $displayServerName
            toolName = $toolName
            exposedName = $exposedName
            structuredRouteSha256 = Get-Utf8Sha256 $routeTuple
        }
        $toolIndex++
    }
    $serverIndex++
}

$manifestSha256 = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$receiptDir = Split-Path -Parent $ReceiptPath
if ($receiptDir) { New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null }
$receipt = [ordered]@{
    schemaVersion = 1
    component = 'windows-mcp-multi-server-tool-identity'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    source = [ordered]@{
        manifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
        manifestSha256 = $manifestSha256
    }
    counts = [ordered]@{
        serverCount = $servers.Count
        toolCount = $routeRecords.Count
        caseInsensitiveExposedNameCollisionCount = $caseInsensitiveCollisionPairs.Count
        rawToolNameRecommendedShapeViolationCount = $recommendedRawToolNameViolations.Count
    }
    routingPolicy = [ordered]@{
        structuredServerIdentityRequired = $true
        serverInfoNameAcceptedAsSoleServerIdentity = $false
        rawToolNameUniquenessScopedPerServer = $true
        globalModelVisibleExposedNameUniquenessRequired = $true
        simplePrefixConcatenationInjectivityProven = $false
        caseInsensitiveNameUniquenessRequiredByMcp = $false
        caseInsensitiveNameCollisionsRecordedForModelRisk = $true
    }
    routes = @($routeRecords)
    observations = [ordered]@{
        caseInsensitiveExposedNameCollisions = @($caseInsensitiveCollisionPairs)
        rawToolNameRecommendedShapeViolations = @($recommendedRawToolNameViolations)
    }
    multiServerToolRoutingAccepted = $true
    acceptanceBoundary = [ordered]@{
        structuredRouteIdentitiesUnique = $true
        globalExposedToolNamesUnique = $true
        serverRuntimeIdentityCryptographicallyProvenByThisReceipt = $false
        liveMcpServerIdentityBound = $false
        liveToolCatalogGenerationBound = $false
        toolExecutionAuthorized = $false
        semanticToolAccepted = $false
        windowsFinalStateAccepted = $false
    }
}

$json = $receipt | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText(
    [System.IO.Path]::GetFullPath($ReceiptPath),
    $json,
    (New-Object System.Text.UTF8Encoding($false))
)
$receipt
