# SteamCMD（macOS，随 App 打包）

本目录为 Valve 官方 **SteamCMD for macOS** 解压后的内容，构建 WaifuX 时会打进 `WaifuX.app/Contents/Resources/steamcmd/`。首次使用 Workshop 相关功能时，应用会把该目录复制到可写的 Application Support 路径再执行（SteamCMD 需要写入配置与自更新缓存）。

## 维护者更新本目录

在仓库根目录执行（会自动下载官方包并写入本目录，**保留**本 `README.md`）：

```bash
./scripts/sync-steamcmd-into-resources.sh
```

离线时可将官方包先解压到任意路径，再执行：

```bash
./scripts/sync-steamcmd-into-resources.sh /path/to/解压后的目录
```

**不要**把 `steamcmd_osx.tar.gz` 留在本目录，以免增大安装包。请勿在仓库根目录再建 `steamcmd/`（已在 `.gitignore` 忽略）。

## 许可

以 Valve 对 SteamCMD 的分发条款为准；仅用于本应用内 Workshop 资源下载等合法用途。
