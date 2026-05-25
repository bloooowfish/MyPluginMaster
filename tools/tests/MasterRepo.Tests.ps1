$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$configPath = Join-Path $repoRoot 'plugins.json'
$repoJsonPath = Join-Path $repoRoot 'repo.json'
$buildScriptPath = Join-Path $repoRoot 'tools\Build-MasterRepo.ps1'
$readmePath = Join-Path $repoRoot 'README.md'

function Assert-Match {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Actual,

        [Parameter(Mandatory = $true)]
        [string] $Pattern,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if ($Actual -notmatch $Pattern) {
        throw "$Message Pattern=[$Pattern] Actual=[$Actual]"
    }
}

function Assert-NotMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Actual,

        [Parameter(Mandatory = $true)]
        [string] $Pattern,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if ($Actual -match $Pattern) {
        throw "$Message Pattern=[$Pattern] Actual=[$Actual]"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

foreach ($path in @($configPath, $repoJsonPath, $buildScriptPath, $readmePath)) {
    if (-not (Test-Path $path)) {
        throw "Missing expected file: $path"
    }
}

$configText = Get-Content -Raw $configPath
Assert-NotMatch -Actual $configText -Pattern '[A-Za-z]:\\' -Message 'Plugin config should not expose local absolute paths.'
Assert-NotMatch -Actual $configText -Pattern 'https://github\.com/' -Message 'Plugin config should not store HTTPS clone remotes.'

$plugins = @($configText | ConvertFrom-Json)
Assert-True -Condition ($plugins.Count -ge 1) -Message 'Plugin config should contain at least one plugin.'

$seen = @{}
foreach ($plugin in $plugins) {
    foreach ($property in @('InternalName', 'Repository', 'ManifestPath', 'ProjectPath', 'AssetName')) {
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string] $plugin.$property)) -Message "Plugin entry should define $property."
    }

    Assert-Match -Actual ([string] $plugin.Repository) -Pattern '^bloooowfish/[A-Za-z0-9_.-]+$' -Message 'Plugin repository should target the subaccount owner.'
    Assert-True -Condition (-not $seen.ContainsKey([string] $plugin.InternalName)) -Message "Duplicate InternalName in plugins.json: $($plugin.InternalName)"
    $seen[[string] $plugin.InternalName] = $true
}

$repoJsonText = Get-Content -Raw $repoJsonPath
Assert-Match -Actual $repoJsonText.TrimStart() -Pattern '^\[' -Message 'Master repo.json should be a JSON array.'
$entries = @($repoJsonText | ConvertFrom-Json)
Assert-True -Condition ($entries.Count -eq $plugins.Count) -Message 'repo.json should contain one entry for each configured plugin.'

$entryNames = @{}
foreach ($entry in $entries) {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string] $entry.InternalName)) -Message 'Each repo entry should have InternalName.'
    Assert-True -Condition (-not $entryNames.ContainsKey([string] $entry.InternalName)) -Message "Duplicate InternalName in repo.json: $($entry.InternalName)"
    $entryNames[[string] $entry.InternalName] = $true
    Assert-True -Condition ($null -ne $entry.IsHide) -Message 'Each repo entry should define IsHide.'
    Assert-True -Condition ($null -ne $entry.DownloadCount) -Message 'Each repo entry should define DownloadCount.'
    Assert-Match -Actual ([string] $entry.DownloadLinkInstall) -Pattern '^https://github\.com/bloooowfish/.+/releases/download/v.+/.+\.zip$' -Message 'Install link should use a GitHub release zip.'
    Assert-Match -Actual ([string] $entry.DownloadLinkUpdate) -Pattern '^https://github\.com/bloooowfish/.+/releases/download/v.+/.+\.zip$' -Message 'Update link should use a GitHub release zip.'
}

$buildScriptText = Get-Content -Raw $buildScriptPath
Assert-Match -Actual $buildScriptText -Pattern 'ConvertTo-Json\s+-InputObject\s+\$entries' -Message 'Build script should preserve repo.json as an array.'
Assert-Match -Actual $buildScriptText -Pattern 'HideWhenReleaseMissing' -Message 'Build script should hide unreleased plugins by default.'
Assert-Match -Actual $buildScriptText -Pattern 'download_count' -Message 'Build script should read GitHub release asset download counts.'
Assert-Match -Actual $buildScriptText -Pattern '\$null -eq \$releasePage' -Message 'Build script should stop download-count pagination on empty release pages.'
Assert-NotMatch -Actual $buildScriptText -Pattern 'UtcNow' -Message 'Build script should not churn LastUpdate for unreleased hidden entries.'
Assert-NotMatch -Actual $buildScriptText -Pattern '@\(\$entries\)\s*\|\s*ConvertTo-Json' -Message 'Build script should not pipe repo entries into ConvertTo-Json.'

$readmeText = Get-Content -Raw $readmePath
Assert-Match -Actual $readmeText -Pattern 'raw\.githubusercontent\.com/bloooowfish/MyPluginMaster/refs/heads/main/repo\.json' -Message 'README should publish the cache-resistant master repository URL.'

Write-Host 'Master repo tests passed.'
