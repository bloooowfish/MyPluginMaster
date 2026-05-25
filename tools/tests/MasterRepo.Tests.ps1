$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$configPath = Join-Path $repoRoot 'plugins.json'
$repoJsonPath = Join-Path $repoRoot 'repo.json'
$buildScriptPath = Join-Path $repoRoot 'tools\Build-MasterRepo.ps1'
$updateScriptPath = Join-Path $repoRoot 'tools\Update-MasterRepo.ps1'
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

foreach ($path in @($configPath, $repoJsonPath, $buildScriptPath, $updateScriptPath, $readmePath)) {
    if (-not (Test-Path $path)) {
        throw "Missing expected file: $path"
    }
}

$configText = Get-Content -Raw $configPath
Assert-NotMatch -Actual $configText -Pattern '[A-Za-z]:\\' -Message 'Plugin config should not expose local absolute paths.'
Assert-NotMatch -Actual $configText -Pattern 'https://github\.com/' -Message 'Plugin config should not store HTTPS clone remotes.'

$pluginJson = Get-Content -Raw $configPath | ConvertFrom-Json
$plugins = @($pluginJson)
Assert-True -Condition ($plugins.Count -ge 1) -Message 'Plugin config should contain at least one plugin.'
$repositories = @($plugins | ForEach-Object {
    if ($_ -is [string]) {
        [string] $_
    }
    else {
        [string] $_.Repository
    }
})
$hasBazookaLens = @($repositories | Where-Object { $_ -eq 'bloooowfish/BazookaLens' }).Count -eq 1
$hasWhereIsMyHead = @($repositories | Where-Object { $_ -eq 'bloooowfish/Where-Is-My-Head-Plugin' }).Count -eq 1
Assert-True -Condition $hasBazookaLens -Message 'Plugin config should include BazookaLens.'
Assert-True -Condition $hasWhereIsMyHead -Message 'Plugin config should include WhereIsMyHead.'

$seen = @{}
foreach ($plugin in $plugins) {
    $repository = if ($plugin -is [string]) {
        [string] $plugin
    }
    else {
        [string] $plugin.Repository
    }

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($repository)) -Message 'Plugin entry should define Repository or be a repository string.'
    Assert-Match -Actual $repository -Pattern '^bloooowfish/[A-Za-z0-9_.-]+$' -Message 'Plugin repository should target the subaccount owner.'
    Assert-True -Condition (-not $seen.ContainsKey($repository)) -Message "Duplicate repository in plugins.json: $repository"
    $seen[$repository] = $true

    if ($plugin -isnot [string]) {
        foreach ($property in @('ProjectPath', 'ManifestPath', 'AssetName', 'InternalName')) {
            if (-not [string]::IsNullOrWhiteSpace([string] $plugin.$property)) {
                Assert-NotMatch -Actual ([string] $plugin.$property) -Pattern '[A-Za-z]:\\' -Message "$property override should not use local absolute paths."
            }
        }
    }
}

$repoJsonText = Get-Content -Raw $repoJsonPath
Assert-Match -Actual $repoJsonText.TrimStart() -Pattern '^\[' -Message 'Master repo.json should be a JSON array.'
$repoEntriesJson = Get-Content -Raw $repoJsonPath | ConvertFrom-Json
$entries = @($repoEntriesJson)
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
Assert-Match -Actual $buildScriptText -Pattern 'Get-RepositoryTree' -Message 'Build script should discover plugin project and manifest paths from the repository tree.'
Assert-Match -Actual $buildScriptText -Pattern 'Resolve-PluginDescriptor' -Message 'Build script should support repository-string plugin entries through convention-based discovery.'
Assert-Match -Actual $buildScriptText -Pattern '\{version\}' -Message 'Build script should still support asset name overrides.'
Assert-Match -Actual $buildScriptText -Pattern '\$null -eq \$releasePage' -Message 'Build script should stop download-count pagination on empty release pages.'
Assert-NotMatch -Actual $buildScriptText -Pattern 'UtcNow' -Message 'Build script should not churn LastUpdate for unreleased hidden entries.'
Assert-NotMatch -Actual $buildScriptText -Pattern '@\(\$entries\)\s*\|\s*ConvertTo-Json' -Message 'Build script should not pipe repo entries into ConvertTo-Json.'

$updateScriptText = Get-Content -Raw $updateScriptPath
Assert-Match -Actual $updateScriptText -Pattern 'Build-MasterRepo\.ps1' -Message 'Manual update script should rebuild repo.json.'
Assert-Match -Actual $updateScriptText -Pattern 'MasterRepo\.Tests\.ps1' -Message 'Manual update script should test repo.json.'
Assert-Match -Actual $updateScriptText -Pattern 'Verify-RepoIdentity\.ps1' -Message 'Manual update script should verify subaccount identity before git operations.'
Assert-Match -Actual $updateScriptText -Pattern '\[switch\]\s*\$Commit' -Message 'Manual update script should make committing explicit.'
Assert-Match -Actual $updateScriptText -Pattern '\[switch\]\s*\$Push' -Message 'Manual update script should make pushing explicit.'
Assert-Match -Actual $updateScriptText -Pattern 'git status --short -- repo\.json' -Message 'Manual update script should commit only generated repo.json changes.'

$readmeText = Get-Content -Raw $readmePath
Assert-Match -Actual $readmeText -Pattern 'raw\.githubusercontent\.com/bloooowfish/MyPluginMaster/refs/heads/main/repo\.json' -Message 'README should publish the cache-resistant master repository URL.'
Assert-Match -Actual $readmeText -Pattern 'Update-MasterRepo\.ps1' -Message 'README should document the manual update script.'

$workflowPath = Join-Path $repoRoot '.github\workflows\update-repo.yml'
$workflowText = Get-Content -Raw $workflowPath
Assert-Match -Actual $workflowText -Pattern 'workflow_dispatch' -Message 'Update workflow should be manually triggerable.'
Assert-Match -Actual $workflowText -Pattern 'run-name: Update Plugin Repository \$\{\{ inputs\.correlation_id \|\| github\.run_id \}\}' -Message 'Update workflow should expose release-script correlation ids in the run name.'
Assert-Match -Actual $workflowText -Pattern 'correlation_id:' -Message 'Update workflow should accept an orchestration correlation id.'
Assert-Match -Actual $workflowText -Pattern 'schedule:' -Message 'Update workflow should have a scheduled fallback for download counts and missed local triggers.'
Assert-Match -Actual $workflowText -Pattern 'cron:' -Message 'Update workflow should define the scheduled fallback.'
Assert-Match -Actual $workflowText -Pattern 'concurrency:' -Message 'Update workflow should serialize repo.json commits.'
Assert-Match -Actual $workflowText -Pattern 'plugin-repository-update' -Message 'Update workflow should use one concurrency group for repo.json updates.'
Assert-NotMatch -Actual $workflowText -Pattern 'repository_dispatch' -Message 'Update workflow should not require cross-repository dispatch tokens.'
Assert-NotMatch -Actual $workflowText -Pattern 'plugin-release' -Message 'Update workflow should not depend on plugin release dispatch events.'

Write-Host 'Master repo tests passed.'
