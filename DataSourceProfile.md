# DataSourceProfile 配置文档

## 概述

此 JSON 配置文件定义了 WallHaven 应用的数据源解析规则。当网站 HTML 结构发生变化时，只需修改此 JSON 文件即可，无需修改代码。

## 文件位置

- **JSON 配置**: `DataSourceProfile.json`
- **Swift 配置**: `Models/FavoriteSource.swift`

## 配置结构

```json
{
  "schemaVersion": "1.0.0",
  "profiles": [
    {
      "id": "唯一标识",
      "name": "显示名称",
      "description": "描述",
      "wallpaper": { /* 壁纸 API 配置 */ },
      "media": { /* 动态壁纸 HTML 解析配置 */ }
    }
  ]
}
```

## 字段详解

### WallpaperSourceProfile (WallHaven API 配置)

| 字段 | 说明 | 示例 |
|------|------|------|
| `provider` | 提供商标识 | `"wallhaven_api"` |
| `displayName` | 显示名称 | `"WallHaven"` |
| `apiBaseURL` | API 基础 URL | `"https://wallhaven.cc/api/v1"` |
| `searchPath` | 搜索路径 | `"/search"` |
| `wallpaperPath` | 壁纸详情路径模板 | `"/w/{id}"` |
| `imageURLTemplate` | 图片 URL 模板 | `"https://w.wallhaven.cc/full/{prefix}/wallhaven-{id}.{ext}"` |
| `authHeaderName` | 认证 Header 名称 | `"X-API-Key"` |

### MediaSourceProfile (MotionBGs HTML 解析配置)

| 字段 | 说明 | 示例 |
|------|------|------|
| `provider` | 提供商标识 | `"motionbgs_html"` |
| `displayName` | 显示名称 | `"MotionBGs"` |
| `baseURL` | 网站基础 URL | `"https://motionbgs.com"` |
| `headers` | HTTP 请求头 | 包含 User-Agent 等 |

#### MediaRouteProfile (路由配置)

| 字段 | 说明 | 示例 |
|------|------|------|
| `home` | 首页路径 | `"/"` |
| `mobile` | 移动端首页 | `"/mobile/"` |
| `tag` | 标签页路径模板 | `"/tag:{slug}/"` |
| `search` | 搜索路径模板 | `"/search?q={query}"` |
| `detail` | 详情页路径模板 | `"/{slug}"` |

#### MediaParsingProfile (解析规则 - **重点**)

这是最关键的部分，定义了如何从 HTML 中提取数据。

##### 1. listItemPatterns (列表项匹配)

用于匹配首页/标签页中的壁纸列表项。支持多个模式，按顺序尝试直到匹配成功。

**当前模式 1** (主要模式):
```regex
<a title="([^"]+)" href=([^ >]+)>.*?<img[^>]+src=([^ >]+)[^>]*>.*?<span class=["']?ttl["']?>(.*?)</span>\s*<span class=["']?frm["']?>\s*(.*?)\s*</span>
```

捕获组说明:
- **Group 1**: 标题 (title 属性)
- **Group 2**: 链接 href (用于提取 slug)
- **Group 3**: 缩略图 URL
- **Group 4**: 显示标题 (ttl class)
- **Group 5**: 分辨率 (frm class)

**注意**: `["']?` 表示引号可选，兼容 `class=ttl` 和 `class="ttl"` 两种格式。

**当前模式 2** (备用模式):
更宽松的模式，用于处理格式不一致的情况。

##### 2. nextPagePatterns (分页链接匹配)

用于匹配"下一页"链接。支持多个模式，按顺序尝试。

| 模式 | 用途 |
|------|------|
| `href\s*=\s*"?([^">\s]+)"?\s*(?=rel="?next"?)` | 标准 rel="next" 链接 |
| `<section[^>]*class=["']?pag["']?[^>]*>.*?<a[^>]*href=["']?([^"'\s]+)["']?[^>]*>\s*Next` | 分页区域中的 Next 链接 |
| `<section class=pag>.*?<a href=([^ >\s]+)>\s*Next` | 简化版分页匹配 |
| `hx-get=["']?([^"'\s]+)["']?` | HTMX 分页 (如 `hx-get="/hx2/latest/6/"`) |
| `<a[^>]*href=["']?([^"'\s]+)["']?[^>]*>\s*Next\s*</a>` | 通用 Next 链接 |
| `<div class=larrow><a class=link--arrowed href=([^ >\s]+)>\s*View More Wallpapers` | "View More" 按钮 |

##### 3. tagPattern (标签匹配)

用于匹配标签页的链接和名称。

```regex
<a href=/tag:([^/]+)/>\s*(?:<picture>.*?</picture>\s*)?(?:<span>)?([^<]+?)(?:</span>)?</a>
```

- **Group 1**: 标签 slug (如 `anime`)
- **Group 2**: 标签显示名称

##### 4. downloadPattern (下载链接匹配)

用于匹配详情页中的下载链接。

```regex
<a href=([^ >]+) rel=nofollow target=_blank>.*?<span class=font-bold>([^<]+)</span>\s*Wallpaper\s*\(([^)]+)\)</div><div class=text-xs>([^<]+)</div>
```

- **Group 1**: 下载链接
- **Group 2**: 分辨率
- **Group 3**: 文件格式
- **Group 4**: 文件大小

##### 5. durationPattern (视频时长匹配)

用于从页面脚本中提取视频时长。

```regex
"duration":\s*"([^"]+)"
```

## 更新流程

当 MotionBGs 网站 HTML 结构发生变化时:

1. **抓取新 HTML**:
   ```bash
   curl -H "User-Agent: Mozilla/5.0" https://motionbgs.com/hx2/latest/5/ -o /tmp/motionbgs.html
   ```

2. **分析 HTML 结构**，找出关键元素的新格式

3. **更新 regex 模式**:
   - 保持捕获组顺序不变
   - 使用 `["']?` 使引号可选
   - 使用 `[^>]*` 和 `.*?` 处理属性顺序变化

4. **验证配置**:
   - 将更新后的 JSON 导入应用
   - 测试首页、标签页、分页是否正常

5. **备份旧配置**:
   - 保留 schemaVersion 历史记录
   - 记录变更原因

## 导入/导出

应用支持通过以下方式导入配置:

```swift
// 从 JSON 文件导入
let data = try Data(contentsOf: jsonFileURL)
let profiles = try DataSourceProfileStore.importProfiles(from: data)

// 导出为 JSON
let jsonString = try DataSourceProfileStore.exportBuiltinCatalogJSON()
```

## 常见变更场景

### 场景 1: class 属性添加引号
**变更前**: `class=ttl`
**变更后**: `class="ttl"`
**解决方案**: 使用 `class=["']?ttl["']?` 兼容两种格式 ✅ (已应用)

### 场景 2: HTML 标签结构变化
**变更前**: `<span class=ttl>标题</span>`
**变更后**: `<div class="title">标题</div>`
**解决方案**: 更新 `listItemPatterns` 匹配新标签

### 场景 3: 分页机制变化
**变更前**: 传统 `<a href="/page/2/">Next</a>`
**变更后**: HTMX `hx-get="/hx2/latest/2/"`
**解决方案**: 在 `nextPagePatterns` 中添加新模式 ✅ (已应用)

### 场景 4: 图片 URL 格式变化
**变更前**: `src="/media/123/image.jpg"`
**变更后**: `src="https://cdn.example.com/image.webp"`
**解决方案**: 更新 `listItemPatterns` 第 3 个捕获组的匹配逻辑

## 调试技巧

1. **使用诊断脚本**:
   ```bash
   swift Diagnostics/MediaServiceDiagnostic.swift
   ```

2. **验证单个 regex**:
   ```swift
   let pattern = "<span class=[\\\"']?ttl[\\\"']?>(.*?)</span>"
   let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
   let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
   print("匹配数量: \(matches.count)")
   ```

3. **查看原始 HTML**:
   浏览器开发者工具 → Network → 找到请求 → Preview/Response

## 注意事项

1. **正则转义**: JSON 中的反斜杠需要双重转义 (`\\`)
2. **捕获组顺序**: 更改捕获组顺序需要同步更新解析代码
3. **性能考虑**: 过于复杂的 regex 可能影响解析性能
4. **向后兼容**: 保留旧模式作为备用，直到确认新模式完全工作

## 版本历史

| 版本 | 日期 | 变更说明 |
|------|------|----------|
| 1.0.0 | 2024-XX-XX | 初始版本，支持 MotionBGs 新版 HTML 结构 |
