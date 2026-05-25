param(
    [switch] $Commit,
    [switch] $Push,
    [string] $Message = 'chore: update plugin repository'
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildScript = Join-Path $PSScriptRoot 'Build-MasterRepo.ps1'
$testScript = Join-Path $PSScriptRoot 'tests\MasterRepo.Tests.ps1'
$identityScript = Join-Path $PSScriptRoot 'Verify-RepoIdentity.ps1'

function Fail {
    param([Parameter(Mandatory = $true)][string] $Message)
    Write-Error $Message
    exit 1
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
    }
}

Set-Location $repoRoot

Invoke-Checked -FilePath 'powershell' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $identityScript)
Invoke-Checked -FilePath 'powershell' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScript)
Invoke-Checked -FilePath 'powershell' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $testScript)

$status = (& git status --short -- repo.json | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($status)) {
    Write-Host 'Master repository is already up to date.'
    return
}

Write-Host 'Pending changes:'
Write-Host $status

if (-not $Commit) {
    Write-Host 'Run again with -Commit to commit the generated repo.json.'
    return
}

Invoke-Checked -FilePath 'git' -Arguments @('add', '--', 'repo.json')
Invoke-Checked -FilePath 'git' -Arguments @('commit', '-m', $Message)

if ($Push) {
    Invoke-Checked -FilePath 'git' -Arguments @('push', 'origin', 'main')
}
else {
    Write-Host 'Committed locally. Run with -Push to push origin/main.'
}
