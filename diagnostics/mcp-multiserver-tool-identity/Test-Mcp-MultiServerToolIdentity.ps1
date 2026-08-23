param(
    [string]$Root = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validator = Join-Path $Root 'Validate-Mcp-MultiServerToolIdentity.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "Validator missing: $validator"
}

function Write-JsonFile([string]$Path, [object]$Value) {
    $json = $Value | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText(
        $Path,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Invoke-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][bool]$ShouldPass,
        [string]$ExpectedFailurePattern
    )

    $caseDir = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
    $manifestPath = Join-Path $caseDir 'manifest.json'
    $receiptPath = Join-Path $caseDir 'receipt.json'
    Write-JsonFile $manifestPath $Manifest

    $thrown = $null
    try {
        $result = & $validator -ManifestPath $manifestPath -ReceiptPath $receiptPath
    }
    catch {
        $thrown = $_
    }

    if ($ShouldPass) {
        if ($null -ne $thrown) { throw "$Name unexpectedly failed: $($thrown.Exception.Message)" }
        if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "$Name did not write receipt." }
        $receipt = (Get-Content -LiteralPath $receiptPath -Raw) | ConvertFrom-Json
        if ($receipt.component -ne 'windows-mcp-multi-server-tool-identity') { throw "$Name receipt component mismatch." }
        if (-not $receipt.multiServerToolRoutingAccepted) { throw "$Name was not accepted." }
        if ($receipt.acceptanceBoundary.serverRuntimeIdentityCryptographicallyProvenByThisReceipt) { throw "$Name overclaimed server runtime identity." }
        if ($receipt.acceptanceBoundary.liveMcpServerIdentityBound) { throw "$Name overclaimed live server binding." }
        if ($receipt.acceptanceBoundary.toolExecutionAuthorized) { throw "$Name overclaimed tool authorization." }
        return $receipt
    }

    if ($null -eq $thrown) { throw "$Name unexpectedly passed." }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedFailurePattern) -and $thrown.Exception.Message -notmatch $ExpectedFailurePattern) {
        throw "$Name failed for wrong reason: $($thrown.Exception.Message)"
    }
    return $null
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("braintrust-multiserver-tool-identity-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $a = ('a' * 64)
    $b = ('b' * 64)

    $baseline = [ordered]@{
        schemaVersion = 1
        servers = @(
            [ordered]@{
                serverIdentitySha256 = $a
                displayServerName = 'alpha'
                tools = @(
                    [ordered]@{ name = 'search'; exposedName = 'alpha_search' },
                    [ordered]@{ name = 'status'; exposedName = 'alpha_status' }
                )
            },
            [ordered]@{
                serverIdentitySha256 = $b
                displayServerName = 'beta'
                tools = @(
                    [ordered]@{ name = 'search'; exposedName = 'beta_search' }
                )
            }
        )
    }
    $baselineReceipt = Invoke-Case -Name 'baseline' -Manifest $baseline -ShouldPass $true
    if ($baselineReceipt.counts.serverCount -ne 2 -or $baselineReceipt.counts.toolCount -ne 3) { throw 'baseline counts mismatch.' }
    if ($baselineReceipt.routes.Count -ne 3) { throw 'baseline route count mismatch.' }
    if ($baselineReceipt.routingPolicy.serverInfoNameAcceptedAsSoleServerIdentity) { throw 'baseline server-name policy mismatch.' }

    # These constants are SHA-256(serverIdentitySha256 + U+001F + toolName),
    # computed independently from the validator. They pin the exact route encoding
    # so PS5.1 and PS7 cannot silently produce edition-specific fingerprints.
    $expectedRouteFingerprints = @{
        'alpha_search' = '90a8e7f64695556f1449c6366201ff130c5d4c9dff31f6c7f3c3505f3bd68b82'
        'alpha_status' = '64853816f775f78c35839c0ce5d431b8e08009cae2737c822472dd2849364a38'
        'beta_search' = 'e4f13744d9e51192865fe3bca28978ec72125aeaced988f543d7640d0f9bc33e'
    }
    foreach ($route in @($baselineReceipt.routes)) {
        $expected = [string]$expectedRouteFingerprints[[string]$route.exposedName]
        if ([string]::IsNullOrWhiteSpace($expected)) { throw "unexpected baseline route: $($route.exposedName)" }
        if ([string]$route.structuredRouteSha256 -cne $expected) {
            throw "structured route fingerprint mismatch for $($route.exposedName): expected=$expected actual=$($route.structuredRouteSha256)"
        }
    }

    $duplicateVisibleName = [ordered]@{
        schemaVersion = 1
        servers = @(
            [ordered]@{ serverIdentitySha256 = $a; displayServerName = 'alpha'; tools = @([ordered]@{ name='search'; exposedName='search' }) },
            [ordered]@{ serverIdentitySha256 = $b; displayServerName = 'beta'; tools = @([ordered]@{ name='search'; exposedName='search' }) }
        )
    }
    Invoke-Case -Name 'duplicate-visible-name' -Manifest $duplicateVisibleName -ShouldPass $false -ExpectedFailurePattern 'Duplicate model-visible exposedName' | Out-Null

    # Prefixing by concatenating server + '_' + tool is not injective.
    # server=a/tool=b_c and server=a_b/tool=c both yield a_b_c.
    $nonInjectivePrefix = [ordered]@{
        schemaVersion = 1
        servers = @(
            [ordered]@{ serverIdentitySha256 = $a; displayServerName = 'a'; tools = @([ordered]@{ name='b_c'; exposedName='a_b_c' }) },
            [ordered]@{ serverIdentitySha256 = $b; displayServerName = 'a_b'; tools = @([ordered]@{ name='c'; exposedName='a_b_c' }) }
        )
    }
    Invoke-Case -Name 'non-injective-prefix' -Manifest $nonInjectivePrefix -ShouldPass $false -ExpectedFailurePattern 'Duplicate model-visible exposedName' | Out-Null

    $duplicateServerIdentity = [ordered]@{
        schemaVersion = 1
        servers = @(
            [ordered]@{ serverIdentitySha256 = $a; displayServerName = 'same-name'; tools = @([ordered]@{ name='x'; exposedName='one_x' }) },
            [ordered]@{ serverIdentitySha256 = $a; displayServerName = 'same-name'; tools = @([ordered]@{ name='y'; exposedName='two_y' }) }
        )
    }
    Invoke-Case -Name 'duplicate-server-identity' -Manifest $duplicateServerIdentity -ShouldPass $false -ExpectedFailurePattern 'Duplicate serverIdentitySha256' | Out-Null

    $duplicateRoute = [ordered]@{
        schemaVersion = 1
        servers = @(
            [ordered]@{
                serverIdentitySha256 = $a
                displayServerName = 'alpha'
                tools = @(
                    [ordered]@{ name='x'; exposedName='alpha_x_1' },
                    [ordered]@{ name='x'; exposedName='alpha_x_2' }
                )
            }
        )
    }
    Invoke-Case -Name 'duplicate-structured-route' -Manifest $duplicateRoute -ShouldPass $false -ExpectedFailurePattern 'Duplicate structured route identity' | Out-Null

    $sameDisplayNameDifferentIdentity = [ordered]@{
        schemaVersion = 1
        servers = @(
            [ordered]@{ serverIdentitySha256 = $a; displayServerName = 'server'; tools = @([ordered]@{ name='x'; exposedName='server_a_x' }) },
            [ordered]@{ serverIdentitySha256 = $b; displayServerName = 'server'; tools = @([ordered]@{ name='x'; exposedName='server_b_x' }) }
        )
    }
    $sameNameReceipt = Invoke-Case -Name 'same-display-name-different-identity' -Manifest $sameDisplayNameDifferentIdentity -ShouldPass $true
    if ($sameNameReceipt.counts.serverCount -ne 2) { throw 'same-display-name server count mismatch.' }

    $caseOnly = [ordered]@{
        schemaVersion = 1
        servers = @(
            [ordered]@{ serverIdentitySha256 = $a; displayServerName = 'alpha'; tools = @([ordered]@{ name='Search'; exposedName='Tool.Search' }) },
            [ordered]@{ serverIdentitySha256 = $b; displayServerName = 'beta'; tools = @([ordered]@{ name='search'; exposedName='tool.search' }) }
        )
    }
    $caseReceipt = Invoke-Case -Name 'case-insensitive-risk-observation' -Manifest $caseOnly -ShouldPass $true
    if ($caseReceipt.counts.caseInsensitiveExposedNameCollisionCount -ne 1) { throw 'case-insensitive collision observation was not recorded.' }
    if ($caseReceipt.routingPolicy.caseInsensitiveNameUniquenessRequiredByMcp) { throw 'MCP case-sensitivity policy was overstated.' }

    Write-Output 'MCP multi-server tool identity contract: PASS'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
