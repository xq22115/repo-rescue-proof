param(
    [string]$LockPath = (Join-Path $PSScriptRoot 'installer-lock.json'),
    [string]$InstallBase = (Join-Path $env:LOCALAPPDATA 'Programs\Braintrust-McpTransportBroker\PowerShell'),
    [string]$ReceiptPath = (Join-Path $env:LOCALAPPDATA 'Programs\Braintrust-McpTransportBroker\PowerShell\transport-broker-install-receipt.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Sha256([string]$Value, [string]$FieldPath) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($Value)) "$FieldPath is required."
    Assert-True ($Value -match '^[0-9A-Fa-f]{64}$') "$FieldPath must be a 64-hex SHA-256 string."
    return $Value.ToLowerInvariant()
}

function Get-RequiredReleaseAsset([object]$Release, [string]$Name) {
    $matches = @($Release.assets | Where-Object { [string]$_.name -eq $Name })
    Assert-True ($matches.Count -eq 1) "GitHub release must contain exactly one asset named '$Name'."
    return $matches[0]
}

function Get-RequiredGitHubAssetDigest([object]$Asset, [string]$Name) {
    $digest = [string]$Asset.digest
    Assert-True ($digest -match '^sha256:(?<hash>[0-9A-Fa-f]{64})$') "GitHub release asset '$Name' is missing supported digest metadata."
    return $Matches.hash.ToLowerInvariant()
}

function Assert-PinnedGitHubReleaseUrl([object]$Asset, [string]$Repository, [string]$Tag) {
    $uri = [Uri][string]$Asset.browser_download_url
    Assert-True ($uri.Scheme -eq 'https' -and $uri.Host -eq 'github.com') "Release asset '$($Asset.name)' is not hosted on expected HTTPS GitHub origin."
    $expectedPrefix = "/$Repository/releases/download/$Tag/"
    Assert-True ($uri.AbsolutePath.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) "Release asset '$($Asset.name)' is not pinned to reviewed release '$Tag'."
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Install-Windows-Mcp-PowerShellTransportBroker.ps1 only supports Windows.'
}
Assert-True (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) 'LOCALAPPDATA is required for the per-user transport broker install.'
Assert-True (Test-Path -LiteralPath $LockPath -PathType Leaf) 'installer-lock.json was not found.'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
Assert-True ([int]$lock.schemaVersion -eq 1) 'Unsupported installer-lock schemaVersion.'
$componentProperty = $lock.components.PSObject.Properties['powershell-transport-broker']
Assert-True ($null -ne $componentProperty -and $null -ne $componentProperty.Value) 'installer-lock.json is missing powershell-transport-broker.'
$component = $componentProperty.Value
$repository = [string]$component.repository
$tag = [string]$component.tag
Assert-True ($repository -eq 'PowerShell/PowerShell') 'PowerShell transport broker repository is not the expected official repository.'
Assert-True ($tag -match '^v(?<version>[0-9]+\.[0-9]+\.[0-9]+)$') 'PowerShell transport broker tag must be an explicit stable semantic version.'
$expectedVersion = $Matches.version
Assert-True (-not [string]::IsNullOrWhiteSpace($component.sha256Sums.name)) 'PowerShell transport broker checksum manifest name is missing.'
$lockedChecksumSha = Assert-Sha256 -Value ([string]$component.sha256Sums.sha256) -FieldPath 'powershell-transport-broker.sha256Sums.sha256'

$architectureSource = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$platformKey = if ($architectureSource -match 'ARM64') { 'windows-arm64' } elseif ($architectureSource -match 'AMD64') { 'windows-amd64' } else { throw "Unsupported Windows architecture '$architectureSource' for the MCP PowerShell transport broker." }
$assetProperty = $component.assets.PSObject.Properties[$platformKey]
Assert-True ($null -ne $assetProperty -and $null -ne $assetProperty.Value) "PowerShell transport broker lock is missing '$platformKey'."
$lockedAsset = $assetProperty.Value
$assetName = [string]$lockedAsset.name
$lockedAssetSha = Assert-Sha256 -Value ([string]$lockedAsset.sha256) -FieldPath "powershell-transport-broker.assets.$platformKey.sha256"

$headers = @{ 'User-Agent' = 'braintrust-windows-mcp-powershell-transport-broker' }
$releaseUri = "https://api.github.com/repos/$repository/releases/tags/$([Uri]::EscapeDataString($tag))"
$release = Invoke-RestMethod -Headers $headers -Uri $releaseUri
Assert-True (-not [bool]$release.draft -and -not [bool]$release.prerelease) 'Locked PowerShell release must not be draft or prerelease.'
Assert-True ([string]$release.tag_name -eq $tag) 'PowerShell release tag differs from installer lock.'

$asset = Get-RequiredReleaseAsset -Release $release -Name $assetName
$checksumAsset = Get-RequiredReleaseAsset -Release $release -Name ([string]$component.sha256Sums.name)
Assert-PinnedGitHubReleaseUrl -Asset $asset -Repository $repository -Tag $tag
Assert-PinnedGitHubReleaseUrl -Asset $checksumAsset -Repository $repository -Tag $tag
$assetApiSha = Get-RequiredGitHubAssetDigest -Asset $asset -Name $assetName
$checksumApiSha = Get-RequiredGitHubAssetDigest -Asset $checksumAsset -Name ([string]$component.sha256Sums.name)
Assert-True ($assetApiSha -eq $lockedAssetSha) 'PowerShell asset GitHub digest differs from installer lock.'
Assert-True ($checksumApiSha -eq $lockedChecksumSha) 'PowerShell checksum manifest GitHub digest differs from installer lock.'

$tempRoot = Join-Path $env:TEMP ('braintrust-pwsh-broker-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$checksumPath = Join-Path $tempRoot ([string]$component.sha256Sums.name)
$archivePath = Join-Path $tempRoot $assetName
$versionRoot = Join-Path ([System.IO.Path]::GetFullPath($InstallBase)) $expectedVersion
$architectureRoot = Join-Path $versionRoot $platformKey
$stagingRoot = $architectureRoot + '.staging-' + [guid]::NewGuid().ToString('N')

try {
    # Verify the small official checksum manifest before downloading the larger broker archive.
    Invoke-WebRequest -Headers $headers -Uri $checksumAsset.browser_download_url -OutFile $checksumPath -UseBasicParsing
    $checksumObservedSha = Get-FileSha256 $checksumPath
    Assert-True ($checksumObservedSha -eq $lockedChecksumSha -and $checksumObservedSha -eq $checksumApiSha) 'PowerShell checksum manifest bytes failed three-way SHA-256 verification.'

    $linePattern = '^(?<hash>[0-9A-Fa-f]{64})\s+\*?' + [regex]::Escape($assetName) + '\s*$'
    $manifestMatches = @(Get-Content -LiteralPath $checksumPath | Where-Object { $_ -match $linePattern })
    Assert-True ($manifestMatches.Count -eq 1) "PowerShell checksum manifest must contain exactly one entry for '$assetName'."
    [void]($manifestMatches[0] -match $linePattern)
    $manifestAssetSha = $Matches.hash.ToLowerInvariant()
    Assert-True ($manifestAssetSha -eq $lockedAssetSha -and $manifestAssetSha -eq $assetApiSha) 'PowerShell archive digest differs across checksum manifest, GitHub release metadata, and installer lock.'

    Invoke-WebRequest -Headers $headers -Uri $asset.browser_download_url -OutFile $archivePath -UseBasicParsing
    $archiveObservedSha = Get-FileSha256 $archivePath
    Assert-True ($archiveObservedSha -eq $lockedAssetSha -and $archiveObservedSha -eq $assetApiSha) 'Downloaded PowerShell archive failed exact SHA-256 verification.'

    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    Expand-Archive -LiteralPath $archivePath -DestinationPath $stagingRoot -Force
    $pwshCandidates = @(Get-ChildItem -LiteralPath $stagingRoot -Filter 'pwsh.exe' -File -Recurse)
    Assert-True ($pwshCandidates.Count -eq 1) "Extracted PowerShell archive must contain exactly one pwsh.exe; observed $($pwshCandidates.Count)."
    $stagedPwshPath = [System.IO.Path]::GetFullPath($pwshCandidates[0].FullName)
    $stagingPrefix = $stagingRoot.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    Assert-True ($stagedPwshPath.StartsWith($stagingPrefix, [System.StringComparison]::OrdinalIgnoreCase)) 'Extracted pwsh.exe escaped the staging root.'
    $relativePwshPath = $stagedPwshPath.Substring($stagingPrefix.Length)
    Assert-True (-not [string]::IsNullOrWhiteSpace($relativePwshPath)) 'Extracted pwsh.exe relative path is empty.'

    $signature = Get-AuthenticodeSignature -FilePath $stagedPwshPath
    Assert-True ([string]$signature.Status -eq 'Valid') "Extracted pwsh.exe Authenticode signature is not Valid: $($signature.Status)."
    Assert-True ($null -ne $signature.SignerCertificate) 'Extracted pwsh.exe did not expose a signer certificate.'

    # This probe string is intentionally single-quoted at the outer PowerShell 5.1 layer.
    # Single quotes inside the child script are escaped by doubling them; backslash is not a PowerShell quote escape.
    $probeScript = '$e=[string]$PSVersionTable.PSEdition;$v=[string]$PSVersionTable.PSVersion;$f=[string][System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription;$p=([System.Diagnostics.ProcessStartInfo].GetProperty(''StandardInputEncoding'') -ne $null);[ordered]@{edition=$e;version=$v;framework=$f;hasStandardInputEncoding=$p}|ConvertTo-Json -Compress'
    $probeOutput = @(& $stagedPwshPath -NoLogo -NoProfile -NonInteractive -Command $probeScript 2>&1)
    $probeExitCode = $LASTEXITCODE
    Assert-True ($probeExitCode -eq 0) "Extracted pwsh.exe runtime probe failed with exit code $probeExitCode."
    $probeText = ($probeOutput -join "`n").Trim()
    Assert-True (-not [string]::IsNullOrWhiteSpace($probeText)) 'Extracted pwsh.exe runtime probe returned no JSON.'
    $probe = $probeText | ConvertFrom-Json
    Assert-True ([string]$probe.edition -eq 'Core') 'PowerShell transport broker must report PSEdition Core.'
    Assert-True ([string]$probe.version -eq $expectedVersion) "PowerShell transport broker version mismatch. expected=$expectedVersion actual=$($probe.version)"
    Assert-True ([bool]$probe.hasStandardInputEncoding) 'PowerShell transport broker modern .NET runtime lacks ProcessStartInfo.StandardInputEncoding.'

    # Install under a dedicated per-user, versioned path. Do not add the broker to PATH; callers must use the receipt-bound exact executable.
    $versionParent = Split-Path -Parent $architectureRoot
    if (-not (Test-Path -LiteralPath $versionParent -PathType Container)) { New-Item -ItemType Directory -Path $versionParent -Force | Out-Null }
    if (Test-Path -LiteralPath $architectureRoot) { Remove-Item -LiteralPath $architectureRoot -Recurse -Force }
    Move-Item -LiteralPath $stagingRoot -Destination $architectureRoot
    $installedPwshPath = [System.IO.Path]::GetFullPath((Join-Path $architectureRoot $relativePwshPath))
    Assert-True (Test-Path -LiteralPath $installedPwshPath -PathType Leaf) 'Installed PowerShell transport broker executable was not found after directory move.'
    $installedPwshSha = Get-FileSha256 $installedPwshPath

    $installedSignature = Get-AuthenticodeSignature -FilePath $installedPwshPath
    Assert-True ([string]$installedSignature.Status -eq 'Valid') 'Installed pwsh.exe Authenticode signature is no longer Valid.'
    Assert-True ($null -ne $installedSignature.SignerCertificate) 'Installed pwsh.exe signer certificate is unavailable.'

    $receiptFullPath = [System.IO.Path]::GetFullPath($ReceiptPath)
    $receiptDirectory = Split-Path -Parent $receiptFullPath
    if (-not [string]::IsNullOrWhiteSpace($receiptDirectory) -and -not (Test-Path -LiteralPath $receiptDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null
    }
    $receipt = [ordered]@{
        schemaVersion = 1
        component = 'windows-mcp-powershell-transport-broker-install'
        generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        sourceRelease = [ordered]@{
            repository = $repository
            tag = $tag
            assetName = $assetName
            assetSha256 = $lockedAssetSha
            checksumManifestName = [string]$component.sha256Sums.name
            checksumManifestSha256 = $lockedChecksumSha
            githubReleaseAssetDigestMatched = $true
            officialChecksumManifestMatched = $true
        }
        installedBroker = [ordered]@{
            platformKey = $platformKey
            executablePath = $installedPwshPath
            executableSha256 = $installedPwshSha
            powershellEdition = [string]$probe.edition
            powershellVersion = [string]$probe.version
            frameworkDescription = [string]$probe.framework
            standardInputEncodingPropertyObserved = [bool]$probe.hasStandardInputEncoding
            authenticodeStatus = [string]$installedSignature.Status
            signerSubject = [string]$installedSignature.SignerCertificate.Subject
            signerThumbprint = [string]$installedSignature.SignerCertificate.Thumbprint
        }
        acceptanceBoundary = [ordered]@{
            officialReleaseTagAccepted = $true
            releaseArtifactExactSha256Accepted = $true
            checksumManifestExactSha256Accepted = $true
            extractedExecutableAuthenticodeValidObserved = $true
            installedExecutableExactSha256Observed = $true
            powershellCoreExactVersionAccepted = $true
            modernDotnetStandardInputEncodingAvailable = $true
            pathMutationPerformed = $false
            automaticUpdateEnabledByInstaller = $false
            productionOdrBrokerIntegrationAccepted = $false
            nativeInstallerExecutionAccepted = $false
            semanticMcpFunctionalityAccepted = $false
            windowsFinalStateAccepted = $false
        }
    }
    $json = $receipt | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($receiptFullPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    $receiptSha = Get-FileSha256 $receiptFullPath

    [pscustomobject][ordered]@{
        component = $receipt.component
        installedPwshPath = $installedPwshPath
        installedPwshSha256 = $installedPwshSha
        powershellVersion = [string]$probe.version
        frameworkDescription = [string]$probe.framework
        receiptPath = $receiptFullPath
        receiptSha256 = $receiptSha
        brokerInstallAccepted = $true
        productionOdrBrokerIntegrationAccepted = $false
        nativeInstallerExecutionAccepted = $false
    }
} finally {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
