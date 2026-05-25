$ErrorActionPreference = 'Stop'

$expectedName = 'bloooowfish'
$expectedEmail = '285025450+bloooowfish@users.noreply.github.com'
$expectedRemotePattern = '^github-bf:bloooowfish/MyPluginMaster\.git$|^git@github-bf:bloooowfish/MyPluginMaster\.git$'
$forbiddenIdentityPatterns = @(
    'https://github\.com/',
    '@gmail\.com',
    '@outlook\.com',
    '@hotmail\.com'
)

function Fail {
    param([Parameter(Mandatory = $true)][string] $Message)
    Write-Error $Message
    exit 1
}

function Read-GitScalar {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    $output = & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "git $($Arguments -join ' ') failed."
    }

    ($output | Out-String).Trim()
}

$name = Read-GitScalar -Arguments @('config', '--local', '--get', 'user.name')
$email = Read-GitScalar -Arguments @('config', '--local', '--get', 'user.email')
$origin = Read-GitScalar -Arguments @('remote', 'get-url', 'origin')
$remotes = Read-GitScalar -Arguments @('remote', '-v')

if ($name -ne $expectedName) {
    Fail "Unexpected git user.name: $name"
}

if ($email -ne $expectedEmail) {
    Fail "Unexpected git user.email: $email"
}

if ($origin -notmatch $expectedRemotePattern) {
    Fail "Unexpected origin remote: $origin"
}

foreach ($pattern in $forbiddenIdentityPatterns) {
    if ($remotes -match $pattern) {
        Fail "Forbidden identity or remote pattern found: $pattern"
    }
}

Write-Host 'Repo identity verified:'
Write-Host "  user.name  = $name"
Write-Host "  user.email = $email"
Write-Host "  origin     = $origin"
Write-Host '  remotes    = SSH-only'
