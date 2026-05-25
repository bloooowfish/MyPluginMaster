# MyPluginMaster

Custom Dalamud repository for bloooowfish plugins.

This repository owns the final `repo.json`. Individual plugin repositories publish release assets and version metadata only.
Local plugin release scripts trigger this repository's update workflow after each successful release. A scheduled fallback also refreshes metadata and download counts.

## Custom Repository URL

```text
https://raw.githubusercontent.com/bloooowfish/MyPluginMaster/refs/heads/main/repo.json
```

## Included Plugins

- Bazooka Lens
- Where Is My Head

## Maintenance

Use `tools\Update-MasterRepo.ps1 -Commit -Push` only when you need to refresh `repo.json` manually.
