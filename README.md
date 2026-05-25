# MyPluginMaster

Custom Dalamud repository for bloooowfish plugins.

## Custom Repository URL

```text
https://raw.githubusercontent.com/bloooowfish/MyPluginMaster/refs/heads/main/repo.json
```

## Included Plugins

- Where Is My Head

Entries are generated from `plugins.json`. A plugin is hidden when its configured release asset is not available yet.

## Update

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-MasterRepo.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\tests\MasterRepo.Tests.ps1
```
