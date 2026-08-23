param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-LfText {
    param([Parameter(Mandatory = $true)][string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

# Normalize the candidate to repository-stable LF bytes before replacement. This
# lets the exact bytes exercised on Windows be committed without a whole-file
# CRLF churn when the canonical Git blob uses LF.
$source = ConvertTo-LfText -Text ([System.IO.File]::ReadAllText($InputPath))
$old = ConvertTo-LfText -Text @'
    $providerMatch = [regex]::Match($PathText, '^(?i:variable):(?<target>.*)$')
    if (-not $providerMatch.Success) {
        return $false
    }

    $target = [string]$providerMatch.Groups['target'].Value
'@
$new = ConvertTo-LfText -Text @'
    # PowerShell accepts both drive-qualified Variable:<target> and provider-
    # qualified Variable::<target> paths. The built-in provider can also be
    # addressed as Microsoft.PowerShell.Core\Variable::<target>. Recognize only
    # these built-in forms; a different module/provider with the same leaf name
    # must not inherit Variable-provider authority from a textual resemblance.
    $target = $null
    $providerQualifiedMatch = [regex]::Match(
        $PathText,
        '^(?i:(?:Microsoft\.PowerShell\.Core\\)?Variable)::(?<target>.*)$'
    )
    if ($providerQualifiedMatch.Success) {
        $target = [string]$providerQualifiedMatch.Groups['target'].Value
    }
    else {
        # Keep the drive-qualified form separate so Variable::PID is not parsed
        # as drive-qualified target ':PID'. Scoped targets such as
        # Variable:global:PID remain valid and are normalized below.
        $driveQualifiedMatch = [regex]::Match($PathText, '^(?i:variable):(?!:)(?<target>.*)$')
        if ($driveQualifiedMatch.Success) {
            $target = [string]$driveQualifiedMatch.Groups['target'].Value
        }
    }

    if ($null -eq $target) {
        return $false
    }
'@

$first = $source.IndexOf($old, [System.StringComparison]::Ordinal)
if ($first -lt 0) {
    if ($source.IndexOf($new, [System.StringComparison]::Ordinal) -ge 0) {
        throw 'Provider-qualified guard patch is already present; refusing an ambiguous second application.'
    }
    throw 'Expected provider-path parser block was not found exactly.'
}
$second = $source.IndexOf($old, $first + $old.Length, [System.StringComparison]::Ordinal)
if ($second -ge 0) {
    throw 'Expected provider-path parser block occurs more than once.'
}

$patched = $source.Substring(0, $first) + $new + $source.Substring($first + $old.Length)
if ($patched.IndexOf($old, [System.StringComparison]::Ordinal) -ge 0) {
    throw 'Legacy provider-path parser unexpectedly remains after patch.'
}
if ($patched.IndexOf($new, [System.StringComparison]::Ordinal) -lt 0) {
    throw 'Provider-qualified parser replacement is missing after patch.'
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
}
[System.IO.File]::WriteAllText($OutputPath, $patched, [System.Text.UTF8Encoding]::new($false))

$bytes = [System.IO.File]::ReadAllBytes($OutputPath)
if ($bytes -contains [byte]13) {
    throw 'Candidate output unexpectedly contains carriage-return bytes.'
}
$hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host ("PROVIDER_QUALIFIED_GUARD_CANDIDATE_SHA256={0}" -f $hash)
Write-Host ("PROVIDER_QUALIFIED_GUARD_CANDIDATE_LENGTH={0}" -f $bytes.Length)
