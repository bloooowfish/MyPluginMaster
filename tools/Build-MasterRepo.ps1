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

function Get-ProjectVersion {
    param([Parameter(Mandatory = $true)][string] $ProjectXml)

    [xml] $project = $ProjectXml
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

function Get-ZipDownloadCount {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $total = 0
    $page = 1
    while ($true) {
        $releasePage = Invoke-GitHubApi -Path "repos/$Repository/releases?per_page=100&page=$page"
        if ($null -eq $releasePage) {
            break
        }

        $releases = @($releasePage)
        if ($releases.Count -eq 0) {
            break
        }

        foreach ($release in $releases) {
            foreach ($asset in @($release.assets)) {
                if (([string] $asset.name) -like '*.zip') {
                    $total += [int] $asset.download_count
                }
            }
        }

        if ($releases.Count -lt 100) {
            break
        }

        $page++
    }

    $total
}

function Find-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $TagName,
        [Parameter(Mandatory = $true)][string] $AssetName
    )

    $release = Invoke-GitHubApiOrNull -Path "repos/$Repository/releases/tags/$TagName"
    if ($null -eq $release) {
        return [PSCustomObject]@{
            Release = $null
            Asset = $null
        }
    }

    $asset = @($release.assets) | Where-Object { [string] $_.name -eq $AssetName } | Select-Object -First 1
    [PSCustomObject]@{
        Release = $release
        Asset = $asset
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
    param([Parameter(Mandatory = $true)][object] $Plugin)

    $repository = [string] $Plugin.Repository
    $manifestText = Read-GitHubTextFile -Repository $repository -Path ([string] $Plugin.ManifestPath) -Ref $DefaultBranch
    $projectText = Read-GitHubTextFile -Repository $repository -Path ([string] $Plugin.ProjectPath) -Ref $DefaultBranch
    $manifest = $manifestText | ConvertFrom-Json
    $version = Get-ProjectVersion -ProjectXml $projectText
    $tagName = "v$version"
    $assetName = ([string] $Plugin.AssetName).Replace('{version}', $version)
    $releaseAsset = Find-ReleaseAsset -Repository $repository -TagName $tagName -AssetName $assetName
    $releaseMissing = $null -eq $releaseAsset.Release -or $null -eq $releaseAsset.Asset

    if ($releaseMissing) {
        $message = "Release asset missing for $repository $tagName/$assetName."
        if ($RequireReleaseAsset) {
            Fail $message
        }

        Write-Warning "$message Entry will be hidden."
    }

    $hideWhenReleaseMissing = ConvertTo-BooleanOrDefault -Value $Plugin.HideWhenReleaseMissing -Default $true
    $isHide = ConvertTo-BooleanOrDefault -Value $Plugin.IsHide -Default ($hideWhenReleaseMissing -and $releaseMissing)
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
        InternalName = $manifest.InternalName
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
        DownloadCount = Get-ZipDownloadCount -Repository $repository
        DownloadLinkInstall = $downloadUrl
        DownloadLinkTesting = $null
        DownloadLinkUpdate = $downloadUrl
        LastUpdate = $lastUpdate
    }
}

if (-not (Test-Path $ConfigPath)) {
    Fail "Missing config file: $ConfigPath"
}

$plugins = @(Get-Content -Raw $ConfigPath | ConvertFrom-Json)
if ($plugins.Count -eq 0) {
    Fail 'Plugin config is empty.'
}

$entries = @()
$seen = @{}
foreach ($plugin in $plugins) {
    $internalName = [string] $plugin.InternalName
    if ([string]::IsNullOrWhiteSpace($internalName)) {
        Fail 'Plugin config entry is missing InternalName.'
    }

    if ($seen.ContainsKey($internalName)) {
        Fail "Duplicate plugin InternalName: $internalName"
    }

    $seen[$internalName] = $true
    $entry = New-StoreEntry -Plugin $plugin
    $entries += $entry
}

$entries = @($entries | Sort-Object { [string] $_.InternalName })
$json = ConvertTo-Json -InputObject $entries -Depth 8
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputPath, $json + [Environment]::NewLine, $utf8NoBom)

Write-Host "Wrote $($entries.Count) plugin entries to $OutputPath."
