# Wallpaper Engine (小红车) 集成分支

## 概述

本分支实现了 Wallpaper Engine Steam 创意工坊的基础数据源接入框架。

## 已完成的功能

### 1. 数据源管理 (WorkshopSourceManager)
- 支持 MotionBG 和 Wallpaper Engine 两个数据源切换
- 自动持久化用户选择
- Keychain 安全存储 Steam 凭证

### 2. 媒体页源切换
- 在媒体探索页 (`MediaExploreContentView`) 添加了数据源切换按钮
- 切换时自动刷新数据
- Toast 提示切换结果

### 3. 数据模型
- `WorkshopWallpaper`: Workshop 壁纸模型
- `SteamPublishedFileResponse`: Steam API 响应解析
- 支持视频、场景、网页等多种壁纸类型

### 4. 服务层
- `WorkshopService`: Steam API 调用和 SteamCMD 下载
- 搜索、分页、下载功能
- 错误处理和状态管理

### 5. 视图模型
- `WorkshopViewModel`: 管理 Workshop 页面状态
- 搜索、排序、加载更多

## 文件结构

```
Services/
├── WorkshopSourceManager.swift    # 数据源管理器
├── WorkshopService.swift          # Steam API 服务

Models/
├── WorkshopWallpaper.swift        # Workshop 壁纸模型

ViewModels/
├── WorkshopViewModel.swift        # Workshop 视图模型

Views/
├── MediaExploreContentView.swift  # 已添加源切换按钮
├── ContentView.swift              # 已添加 WorkshopSourceSwitchToast
```

## 下一步工作

1. **SteamCMD 集成**: 将 steamcmd 可执行文件添加到 Resources/steamcmd/
2. **预渲染引擎**: 实现场景/网页壁纸到视频的预渲染
3. **Workshop 浏览页面**: 创建独立的 Workshop 浏览界面
4. **下载管理**: 集成到现有的 DownloadTaskService
5. **设置页面**: 添加 Steam 账号配置界面

## 使用方法

1. 在媒体探索页点击 "MotionBG" 旁边的切换按钮
2. 切换到 "小红车" 即可浏览 Wallpaper Engine 内容
3. 需要配置 SteamCMD 后才能下载内容

## 注意事项

- 当前只实现了基础框架，Steam API 调用需要网络可达
- 预渲染功能需要进一步开发
- SteamCMD 需要单独下载并放入 Resources/steamcmd/ 目录
