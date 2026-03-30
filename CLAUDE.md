# WallHaven 项目规则

## 项目概述

WallHaven 是一款 macOS 壁纸应用，支持 WallHaven 壁纸和 MotionBGs 动态背景。

**仓库：**
- 项目代码：`https://github.com/jipika/WallHaven`（私有）
- 规则配置：`https://github.com/jipika/WallHaven-Profiles`（公开）

## 架构说明

### 双规则系统

1. **DataSourceProfile** (`Resources/DataSourceProfile.json`)
   - 内置配置：WallHaven API + MotionBGs 媒体解析规则
   - 使用 CSS 选择器解析网页
   - 保存位置：UserDefaults

2. **RuleRepository** (`Services/RuleRepository.swift`)
   - 从 GitHub 仓库下载规则
   - 用户只需填入仓库 URL，App 自动同步所有规则
   - 支持：壁纸规则、媒体配置、动漫规则

### 核心服务

| 服务 | 用途 |
|------|------|
| `MediaService` | 解析 MotionBGs 网页获取媒体列表 |
| `WallhavenAPI` | WallHaven API 调用 |
| `AnimeParser` | 动漫解析服务 |
| `HTMLParser` | HTML/CSS 选择器解析 |

## 开发规范

### 1. HTML/CSS 选择器

**重要：** 使用 SwiftSoup 解析 HTML，它只支持 CSS 选择器，不支持 XPath。

```swift
// 正确 ✅
let elements = try document.select("a[title*='live wallpaper']")

// 错误 ❌
let elements = try document.select("//a[contains(@title, 'live')]")
```

### 2. 规则配置格式

CSS 选择器配置示例：
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

### 3. 规则仓库同步

当用户配置 GitHub 仓库 URL 时：
1. `RuleRepository` 从 `index.json` 获取规则索引
2. 下载 `DataSourceProfile.json` 保存到 UserDefaults
3. 下载动漫规则保存到 `AnimeRuleStore`

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

## 文件结构

```
WallHaven/
├── App/              # 应用入口
├── Models/           # 数据模型
├── Views/            # SwiftUI 视图
├── ViewModels/       # 视图模型
├── Services/         # 业务服务
├── Components/       # 可复用组件
├── Utilities/        # 工具类
├── DesignSystem/     # 设计系统
├── Resources/        # 资源文件
│   └── DataSourceProfile.json  # 内置媒体配置
├── AnimeRules/       # 动漫规则示例
├── Rules/            # 壁纸规则示例
├── Docs/             # 文档
├── Design/           # 设计资源
└── project.yml       # XcodeGen 配置
```

## 常用命令

```bash
# 生成 Xcode 项目
xcodegen generate

# 构建项目
xcodebuild -project WallHaven.xcodeproj -scheme WallHaven build
```

## 注意事项

1. **不要修改 `Rules/` 目录的示例规则** - 示例仅作参考
2. **规则配置使用 CSS 选择器** - 不是 XPath
3. **用户只填 GitHub URL** - App 自动处理所有规则同步
4. **保持 MediaService 简洁** - 解析逻辑尽量在配置中

## 已知问题

- MotionBGs 网站结构可能变化，需要更新 CSS 选择器
- 动漫规则需要维护真实可用的源
