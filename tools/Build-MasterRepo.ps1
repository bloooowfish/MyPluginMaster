param(
    [string] $ConfigPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'plugins.json'),
    [string] $OutputPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'repo.json'),
    [string] $DefaultBranch = 'main',
    [switch] $RequireReleaseAsset
)

$ErrorActionPreference = 'Stop'

function Fail {
    param([Parameter(Mandatory = $true)][string] $Message)
    Write-Error $Message
    exit 1
}

function New-GitHubHeaders {
    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'User-Agent' = 'MyPluginMaster'
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
    }

    return $headers
}

function Invoke-GitHubApi {
    param([Parameter(Mandatory = $true)][string] $Path)

    $uri = "https://api.github.com/$Path"
    Invoke-RestMethod -Method Get -Uri $uri -Headers (New-GitHubHeaders)
}

function Invoke-GitHubApiOrNull {
    param([Parameter(Mandatory = $true)][string] $Path)

    try {
        Invoke-GitHubApi -Path $Path
    }
    catch {
        $response = $_.Exception.Response
        if ($null -ne $response -and [int] $response.StatusCode -eq 404) {
            return $null
        }

        throw
    }
}

function ConvertTo-GitHubContentPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $segments = ($Path -replace '\\', '/') -split '/' |
        ForEach-Object { [System.Uri]::EscapeDataString($_) }

    [string]::Join('/', $segments)
}

function Read-GitHubTextFile {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Ref
    )

    $contentPath = ConvertTo-GitHubContentPath -Path $Path
    $content = Invoke-GitHubApi -Path "repos/$Repository/contents/$contentPath`?ref=$Ref"
    $base64 = [string] $content.content -replace '\s', ''
    $bytes = [System.Convert]::FromBase64String($base64)
    [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Normalize-RepositoryPath {
    param([AllowEmptyString()][string] $Path)

    ($Path -replace '\\', '/').Trim('/')
}

function Get-RepositoryPathDirectory {
    param([Parameter(Mandatory = $true)][string] $Path)

    $normalized = Normalize-RepositoryPath -Path $Path
    $lastSlash = $normalized.LastIndexOf('/')
    if ($lastSlash -lt 0) {
        return ''
    }

    $normalized.Substring(0, $lastSlash)
}

function Join-RepositoryPath {
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $normalizedDirectory = Normalize-RepositoryPath -Path $Directory
    if ([string]::IsNullOrWhiteSpace($normalizedDirectory)) {
        return $Name
    }

    "$normalizedDirectory/$Name"
}

function Get-RepositoryTree {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Ref
    )

    $tree = Invoke-GitHubApi -Path "repos/$Repository/git/trees/$Ref`?recursive=1"
    if ([bool] $tree.truncated) {
        Fail "Repository tree is truncated for $Repository@$Ref. Add explicit ProjectPath and ManifestPath overrides."
    }

    @($tree.tree) | Where-Object { [string] $_.type -eq 'blob' }
}

function Get-PluginRepository {
    param([Parameter(Mandatory = $true)][object] $Plugin)

    if ($Plugin -is [string]) {
        return [string] $Plugin
    }

    [string] $Plugin.Repository
}

function Get-PluginOverride {
    param(
        [Parameter(Mandatory = $true)][object] $Plugin,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($Plugin -is [string]) {
        return ''
    }

    $property = $Plugin.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }

    [string] $property.Value
}

function Assert-TreePath {
    param(
        [Parameter(Mandatory = $true)][object[]] $Tree,
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $normalizedPath = Normalize-RepositoryPath -Path $Path
    $matched = @($Tree | Where-Object { [string] $_.path -eq $normalizedPath }).Count -gt 0
    if (-not $matched) {
        Fail "Repository $Repository does not contain expected path: $normalizedPath"
    }
}

function Resolve-PluginDescriptor {
    param(
        [Parameter(Mandatory = $true)][object] $Plugin,
        [Parameter(Mandatory = $true)][string] $Ref
    )

    $repository = Get-PluginRepository -Plugin $Plugin
    if ([string]::IsNullOrWhiteSpace($repository)) {
        Fail 'Plugin config entry should be a repository string or define Repository.'
    }

    $tree = @(Get-RepositoryTree -Repository $repository -Ref $Ref)
    $projectPath = Normalize-RepositoryPath -Path (Get-PluginOverride -Plugin $Plugin -Name 'ProjectPath')
    $manifestPath = Normalize-RepositoryPath -Path (Get-PluginOverride -Plugin $Plugin -Name 'ManifestPath')

    if (-not [string]::IsNullOrWhiteSpace($projectPath)) {
        Assert-TreePath -Tree $tree -Repository $repository -Path $projectPath
    }
    else {
        $paths = @($tree | ForEach-Object { [string] $_.path })
        $candidates = @()
        foreach ($path in $paths) {
            if (-not $path.EndsWith('.csproj', [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $directory = Get-RepositoryPathDirectory -Path $path
            $projectName = [System.IO.Path]::GetFileNameWithoutExtension($path)
            $candidateManifestPath = Join-RepositoryPath -Directory $directory -Name "$projectName.json"
            if ($paths -contains $candidateManifestPath) {
                $candidates += [PSCustomObject]@{
                    ProjectPath = $path
                    ManifestPath = $candidateManifestPath
                }
            }
        }

        if ($candidates.Count -eq 0) {
            Fail "Could not discover plugin project for $repository. Expected a .csproj with a same-directory, same-name .json manifest."
        }

        if ($candidates.Count -gt 1) {
            $candidateList = ($candidates | ForEach-Object { $_.ProjectPath }) -join ', '
            Fail "Multiple plugin project candidates found for $repository`: $candidateList. Add explicit ProjectPath and ManifestPath overrides."
        }

        $projectPath = [string] $candidates[0].ProjectPath
        if ([string]::IsNullOrWhiteSpace($manifestPath)) {
            $manifestPath = [string] $candidates[0].ManifestPath
        }
    }

    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        $projectDirectory = Get-RepositoryPathDirectory -Path $projectPath
        $projectName = [System.IO.Path]::GetFileNameWithoutExtension($projectPath)
        $manifestPath = Join-RepositoryPath -Directory $projectDirectory -Name "$projectName.json"
    }

    Assert-TreePath -Tree $tree -Repository $repository -Path $manifestPath

    [PSCustomObject]@{
        Repository = $repository
        ProjectPath = $projectPath
        ManifestPath = $manifestPath
    }
}

function Get-ProjectVersion {
    param([Parameter(Mandatory = $true)][string] $ProjectXml)

    [xml] $project = $ProjectXml.TrimStart([char] 0xFEFF)
    $version = $project.Project.PropertyGroup |
        ForEach-Object { $_.Version } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace([string] $version)) {
        Fail 'Project file does not define a Version property.'
    }

    [string] $version
}

function Get-UnixTimeSeconds {
    param([Parameter(Mandatory = $true)][DateTimeOffset] $Value)

    [string] $Value.ToUnixTimeSeconds()
}

function Get-ReleaseInventory {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $releases = @()
    $page = 1
    while ($true) {
        $releasePage = Invoke-GitHubApi -Path "repos/$Repository/releases?per_page=100&page=$page"
        if ($null -eq $releasePage) {
            break
        }

        $currentPage = @($releasePage)
        if ($currentPage.Count -eq 0) {
            break
        }

        $releases += $currentPage

        if ($currentPage.Count -lt 100) {
            break
        }

        $page++
    }

    $releases
}

function Get-ZipDownloadCount {
    param([Parameter(Mandatory = $true)][object[]] $Releases)

    $total = 0
    foreach ($release in $Releases) {
        foreach ($asset in @($release.assets)) {
            if (([string] $asset.name) -like '*.zip') {
                $total += [int] $asset.download_count
            }
        }
    }

    $total
}

function Get-AssetVersionPattern {
    param([Parameter(Mandatory = $true)][string] $AssetNameTemplate)

    if ($AssetNameTemplate.IndexOf('{version}', [StringComparison]::Ordinal) -lt 0) {
        Fail "AssetName must contain {version}: $AssetNameTemplate"
    }

    $escapedTemplate = [regex]::Escape($AssetNameTemplate)
    $escapedPlaceholder = [regex]::Escape('{version}')
    "^$($escapedTemplate.Replace($escapedPlaceholder, '(?<version>\d+\.\d+\.\d+\.\d+)'))$"
}

function Find-LatestReleaseAsset {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][object[]] $Releases,
        [Parameter(Mandatory = $true)][string] $AssetNameTemplate
    )

    $assetPattern = Get-AssetVersionPattern -AssetNameTemplate $AssetNameTemplate
    $publishedStableReleases = @($Releases |
        Where-Object { -not [bool] $_.draft -and -not [bool] $_.prerelease } |
        Sort-Object -Descending { [DateTimeOffset]::Parse([string] $_.published_at) })

    foreach ($release in $publishedStableReleases) {

        foreach ($asset in @($release.assets)) {
            $assetName = [string] $asset.name
            $match = [regex]::Match($assetName, $assetPattern)
            if ($match.Success) {
                return [PSCustomObject]@{
                    Release = $release
                    Asset = $asset
                    Version = [string] $match.Groups['version'].Value
                }
            }
        }
    }

    [PSCustomObject]@{
        Release = $null
        Asset = $null
        Version = ''
    }
}

function ConvertTo-BooleanOrDefault {
    param(
        [object] $Value,
        [bool] $Default
    )

    if ($null -eq $Value) {
        return $Default
    }

    [bool] $Value
}

function New-StoreEntry {
    param(
        [Parameter(Mandatory = $true)][object] $Plugin,
        [object] $ExistingEntry
    )

    $descriptor = Resolve-PluginDescriptor -Plugin $Plugin -Ref $DefaultBranch
    $repository = [string] $descriptor.Repository
    $manifestText = Read-GitHubTextFile -Repository $repository -Path ([string] $descriptor.ManifestPath) -Ref $DefaultBranch
    $manifest = $manifestText | ConvertFrom-Json
    $internalName = if (-not [string]::IsNullOrWhiteSpace((Get-PluginOverride -Plugin $Plugin -Name 'InternalName'))) {
        Get-PluginOverride -Plugin $Plugin -Name 'InternalName'
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string] $manifest.InternalName)) {
        [string] $manifest.InternalName
    }
    else {
        [System.IO.Path]::GetFileNameWithoutExtension([string] $descriptor.ProjectPath)
    }

    $assetNameTemplate = Get-PluginOverride -Plugin $Plugin -Name 'AssetName'
    if ([string]::IsNullOrWhiteSpace($assetNameTemplate)) {
        $assetNameTemplate = "$internalName-{version}.zip"
    }

    $releases = @(Get-ReleaseInventory -Repository $repository)
    $releaseAsset = Find-LatestReleaseAsset -Repository $repository -Releases $releases -AssetNameTemplate $assetNameTemplate
    $releaseMissing = $null -eq $releaseAsset.Release -or $null -eq $releaseAsset.Asset

    if ($releaseMissing) {
        $message = "No published stable release asset matching $assetNameTemplate was found for $repository."
        if ($RequireReleaseAsset) {
            Fail $message
        }

        if ($null -ne $ExistingEntry) {
            Write-Warning "$message Preserving the existing repository entry."
            return $ExistingEntry
        }

        Write-Warning "$message Entry will be hidden."

        $projectText = Read-GitHubTextFile -Repository $repository -Path ([string] $descriptor.ProjectPath) -Ref $DefaultBranch
        $version = Get-ProjectVersion -ProjectXml $projectText
        $tagName = "v$version"
        $assetName = $assetNameTemplate.Replace('{version}', $version)
    }
    else {
        $version = [string] $releaseAsset.Version
        $tagName = [string] $releaseAsset.Release.tag_name
        $assetName = [string] $releaseAsset.Asset.name
        $manifestText = Read-GitHubTextFile -Repository $repository -Path ([string] $descriptor.ManifestPath) -Ref $tagName
        $manifest = $manifestText | ConvertFrom-Json
    }

    $hideWhenReleaseMissingOverride = Get-PluginOverride -Plugin $Plugin -Name 'HideWhenReleaseMissing'
    $isHideOverride = Get-PluginOverride -Plugin $Plugin -Name 'IsHide'
    $hideWhenReleaseMissing = if ([string]::IsNullOrWhiteSpace($hideWhenReleaseMissingOverride)) {
        $true
    }
    else {
        [bool]::Parse($hideWhenReleaseMissingOverride)
    }
    $isHide = if ([string]::IsNullOrWhiteSpace($isHideOverride)) {
        $hideWhenReleaseMissing -and $releaseMissing
    }
    else {
        [bool]::Parse($isHideOverride)
    }
    $downloadUrl = "https://github.com/$repository/releases/download/$tagName/$assetName"
    $lastUpdate = if ($null -ne $releaseAsset.Release -and -not [string]::IsNullOrWhiteSpace([string] $releaseAsset.Release.published_at)) {
        Get-UnixTimeSeconds -Value ([DateTimeOffset]::Parse([string] $releaseAsset.Release.published_at))
    }
    else {
        '0'
    }

    [ordered]@{
        Author = $manifest.Author
        Name = $manifest.Name
        InternalName = $internalName
        AssemblyVersion = $version
        TestingAssemblyVersion = $null
        Description = $manifest.Description
        Punchline = $manifest.Punchline
        ApplicableVersion = if ([string]::IsNullOrWhiteSpace([string] $manifest.ApplicableVersion)) { 'any' } else { $manifest.ApplicableVersion }
        Tags = @($manifest.Tags)
        RepoUrl = "https://github.com/$repository"
        DalamudApiLevel = if ($null -eq $manifest.DalamudApiLevel) { 15 } else { $manifest.DalamudApiLevel }
        TestingDalamudApiLevel = $null
        IsHide = $isHide
        IsTestingExclusive = $false
        DownloadCount = Get-ZipDownloadCount -Releases $releases
        DownloadLinkInstall = $downloadUrl
        DownloadLinkTesting = $null
        DownloadLinkUpdate = $downloadUrl
        LastUpdate = $lastUpdate
    }
}

if (-not (Test-Path $ConfigPath)) {
    Fail "Missing config file: $ConfigPath"
}

$pluginJson = Get-Content -Raw $ConfigPath | ConvertFrom-Json
$plugins = @($pluginJson)
if ($plugins.Count -eq 0) {
    Fail 'Plugin config is empty.'
}

$existingEntriesByRepository = @{}
if (Test-Path $OutputPath) {
    try {
        $existingEntries = @(Get-Content -Raw $OutputPath | ConvertFrom-Json)
        foreach ($existingEntry in $existingEntries) {
            $repoUrl = [string] $existingEntry.RepoUrl
            $match = [regex]::Match($repoUrl, '^https://github\.com/(?<repository>[^/]+/[^/]+)/?$')
            if ($match.Success) {
                $existingEntriesByRepository[$match.Groups['repository'].Value] = $existingEntry
            }
        }
    }
    catch {
        Write-Warning "Could not read existing repository metadata for failure preservation: $($_.Exception.Message)"
    }
}

$entries = @()
$seenRepositories = @{}
$seenInternalNames = @{}
foreach ($plugin in $plugins) {
    $repository = Get-PluginRepository -Plugin $plugin
    if ([string]::IsNullOrWhiteSpace($repository)) {
        Fail 'Plugin config entry should be a repository string or define Repository.'
    }

    if ($seenRepositories.ContainsKey($repository)) {
        Fail "Duplicate plugin repository: $repository"
    }

    $seenRepositories[$repository] = $true
    $existingEntry = $existingEntriesByRepository[$repository]
    $entry = New-StoreEntry -Plugin $plugin -ExistingEntry $existingEntry
    if ($seenInternalNames.ContainsKey([string] $entry.InternalName)) {
        Fail "Duplicate plugin InternalName: $($entry.InternalName)"
    }

    $seenInternalNames[[string] $entry.InternalName] = $true
    $entries += $entry
}

$entries = @($entries | Sort-Object { [string] $_.InternalName })
$json = ConvertTo-Json -InputObject $entries -Depth 8
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputPath, $json + [Environment]::NewLine, $utf8NoBom)

Write-Host "Wrote $($entries.Count) plugin entries to $OutputPath."
