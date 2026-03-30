# WallHaven 项目规则

## 项目概述

WallHaven 是一款 macOS 壁纸应用，支持 WallHaven 壁纸、MotionBGs 动态背景和动漫视频解析。

**仓库：**
- 项目代码：`https://github.com/jipika/WallHaven`（私有）
- 规则配置：`https://github.com/jipika/WallHaven-Profiles`（公开）

## 架构说明

### 三层规则系统

```
用户输入 GitHub URL → RuleRepository 自动同步 → App 使用规则
```

| 规则类型 | 来源 | 说明 |
|---------|------|------|
| **DataSourceProfile** | GitHub 仓库 | WallHaven API + MotionBGs 媒体配置 |
| **DataSourceRule** | GitHub 仓库 | 壁纸解析规则（XPath） |
| **AnimeRule** | GitHub 仓库 | 动漫解析规则（CSS 选择器） |

### 核心服务

| 服务 | 用途 |
|------|------|
| `MediaService` | 解析 MotionBGs 网页获取媒体列表 |
| `WallhavenAPI` | WallHaven API 调用 |
| `AnimeParser` | 动漫搜索、详情、视频解析 |
| `AnimeRuleStore` | 动漫规则管理（加载、更新、删除） |
| `HTMLParser` | HTML/CSS 选择器解析引擎 |
| `RuleRepository` | GitHub 规则仓库同步 |

### 数据流向

```
GitHub Repository
     │
     ▼
RuleRepository.syncAllRules()
     │
     ├──► DataSourceProfile ──► UserDefaults ──► MediaService
     │
     ├──► DataSourceRule ──► RuleLoader ──► ContentService
     │
     └──► AnimeRule ──► AnimeRuleStore ──► AnimeParser
```

## 开发规范

### 1. HTML/CSS 选择器

**重要：** 使用 SwiftSoup 解析 HTML，它只支持 CSS 选择器，不支持 XPath。

```swift
// 正确 ✅
let elements = try document.select("a[title*='live wallpaper']")
let title = try element.select("span.ttl").first()?.text()

// 错误 ❌
let elements = try document.select("//a[contains(@title, 'live')]")
```

### 2. CSS 选择器速查

| 功能 | CSS 选择器 |
|------|----------|
| class 选择器 | `.className` |
| 多个 class | `.class1.class2` |
| 属性包含 | `[title*='wallpaper']` |
| 属性开头 | `[href^='/tag:']` |
| 子元素 | `a > img` |
| 后代元素 | `div img` |

### 3. 规则配置格式

**DataSourceProfile (CSS 选择器)**：
```json
{
  "parsing": {
    "searchList": "a[title*='live wallpaper']",
    "searchName": "span.ttl",
    "searchResult": "href",
    "searchCover": "img"
  }
}
```

**AnimeRule (CSS 选择器)**：
```json
{
  "searchURL": "https://example.com/search?q={keyword}",
  "searchList": ".video-item",
  "searchName": ".title",
  "searchCover": "img",
  "detailTitle": ".detail-title",
  "videoSelector": "video source",
  "videoSourceAttr": "src"
}
```

## GitHub 规则仓库结构

```
WallHaven-Profiles/
├── index.json              # 规则索引
├── wallhaven.json          # WallHaven 壁纸规则
├── DataSourceProfile.json   # 媒体配置
└── anime/
    ├── index.json          # 动漫规则索引
    ├── age.json            # AGE 动漫源
    ├── gimy.json           # Gimy 动漫源
    ├── dm84.json           # DM84 动漫源
    └── 7sefun.json         # 7sefun 动漫源
```

## Git 工作流程

### 分支命名
- `main` - 主分支（保护）
- `feature/*` - 功能分支
- `fix/*` - 修复分支

### 提交规范
```
feat: 添加新功能
fix: 修复 bug
docs: 文档更新
refactor: 重构
chore: 构建/工具更新
```

## 发布工作流

### 自动发布（推荐）
```bash
# 创建标签并推送
git tag v1.0.0
git push origin v1.0.0
```
推送标签后，GitHub Actions 自动构建并创建 Draft Release。

### 手动发布
在 GitHub Actions 页面点击 "Release" workflow → "Run workflow"

## 文件结构

```
WallHaven/
├── App/                  # 应用入口
├── Models/               # 数据模型
│   ├── AnimeRule.swift   # 动漫规则模型
│   ├── MediaItem.swift   # 媒体项模型
│   └── Wallpaper.swift   # 壁纸模型
├── Views/                # SwiftUI 视图
├── ViewModels/           # 视图模型
├── Services/            # 业务服务
│   ├── MediaService.swift      # 媒体解析服务
│   ├── AnimeParser.swift       # 动漫解析服务
│   ├── AnimeRuleStore.swift    # 动漫规则管理
│   ├── HTMLParser.swift       # HTML/CSS 解析引擎
│   └── RuleRepository.swift    # GitHub 规则同步
├── Components/           # 可复用组件
├── Utilities/           # 工具类
├── DesignSystem/       # 设计系统
├── Resources/          # 资源文件
│   └── DataSourceProfile.json  # 内置媒体配置
├── Rules/              # 规则示例
│   └── gimy-example.json     # 规则示例
├── Docs/               # 文档
├── Design/             # 设计资源
└── project.yml         # XcodeGen 配置
```

## 常用命令

```bash
# 生成 Xcode 项目
xcodegen generate

# 构建项目
xcodebuild -project WallHaven.xcodeproj -scheme WallHaven build

# 创建发布标签
git tag v1.0.0 && git push origin v1.0.0
```

## 注意事项

1. **规则配置使用 CSS 选择器** - SwiftSoup 不支持 XPath
2. **用户只填 GitHub URL** - App 自动处理所有规则同步
3. **保持解析服务简洁** - 解析逻辑尽量在配置中
4. **AnimeRules 目录已删除** - 规则统一放在 GitHub 仓库
5. **Resources 目录需要打包** - 确保 project.yml 包含 Resources

## 已知问题

- MotionBGs 网站结构可能变化，需要更新 CSS 选择器
- 动漫规则需要维护真实可用的源
- GitHub Actions 需要 macOS Runner（付费）

## 调试技巧

### 查看日志
App 运行时会输出解析日志：
```
[MediaService] parseListPage: found 20 elements
[AnimeParser] search: found 10 results
```

### 测试 CSS 选择器
在 Safari/WebKit 中使用 `document.querySelectorAll("selector")` 测试选择器。
