---
name: MotionBGs 分页加载失败诊断
overview: 诊断 MotionBGs 媒体列表页分页加载失败的根本原因，重点检查选择器配置、页面结构变化和分页逻辑
todos:
  - id: explore-pagination-code
    content: 使用 [subagent:code-explorer] 深入探索 MediaService 的分页逻辑实现，包括 parseNextPagePath、makePageURL 和 loadMore 的完整调用链
    status: completed
  - id: check-website-manually
    content: 手动在浏览器中检查 motionbgs.com 的分页结构，使用开发者工具确认实际的 HTML 元素和选择器
    status: completed
  - id: add-diagnostic-logging
    content: 在 MediaService.swift 的 parseNextPagePath 函数中添加详细诊断日志，输出所有可能的分页链接
    status: completed
    dependencies:
      - explore-pagination-code
  - id: run-diagnostic
    content: 运行 MediaServiceDiagnostic.swift 诊断脚本，分析输出结果
    status: completed
    dependencies:
      - add-diagnostic-logging
  - id: update-rule-or-code
    content: 根据诊断结果，更新 DataSourceProfile.json（规则库）或修复 MediaService.swift 的分页逻辑
    status: completed
    dependencies:
      - run-diagnostic
  - id: test-pagination
    content: 在 App 中测试分页功能，验证首页、标签页、搜索页的分页是否正常工作
    status: completed
    dependencies:
      - update-rule-or-code
---

## 问题概述

用户报告媒体列表页分页加载失败。需要检查 MotionBGs 网站（https://motionbgs.com）的分页机制，验证规则配置是否正确，并修复问题。

## 核心需求

1. **诊断分页失败原因**：通过实际访问 MotionBGs 网站，检查 HTML 结构变化
2. **验证规则配置**：确认 DataSourceProfile.json 中的分页选择器是否仍然有效
3. **修复规则或代码**：根据网站实际结构更新规则库或修复解析代码
4. **测试验证**：确保分页功能正常工作

## 问题分析

基于代码审查，当前配置：

- **分页选择器**：`a[rel='next']`（来自 DataSourceProfile.json）
- **解析逻辑**：MediaService.swift 的 `parseNextPagePath` 函数
- **潜在问题**：网站可能更新了 HTML 结构，选择器不再匹配

## 技术方案

### 诊断策略

**步骤 1：手动检查网站结构**
由于无法直接使用浏览器工具，需要手动检查：

1. 在浏览器中打开 https://motionbgs.com
2. 使用开发者工具检查分页元素
3. 确认分页链接的实际 HTML 结构
4. 记录实际的选择器（可能是 `.pagination a.next`、`a.page-next` 等）

**步骤 2：代码层面的诊断**

添加详细的调试日志到 `MediaService.swift` 的 `parseNextPagePath` 函数：

```swift
private func parseNextPagePath(html: String, source: MediaRouteSource, pageURL: URL) -> String? {
    // 添加诊断：打印 HTML 中所有的 a 标签及其 rel 属性
    if let document = try? SwiftSoup.parse(html) {
        if let allLinks = try? document.select("a") {
            print("[MediaService] parseNextPagePath: found \(allLinks.count) links")
            for link in allLinks.array().prefix(20) {
                if let href = try? link.attr("href"),
                   let rel = try? link.attr("rel"),
                   !rel.isEmpty {
                    print("[MediaService] link: href=\(href), rel=\(rel)")
                }
            }
        }
    }
    
    // 原有逻辑...
}
```

**步骤 3：可能的修复方案**

**情况 A：分页选择器错误**
如果 `a[rel='next']` 不存在，需要更新 `DataSourceProfile.json`：

```
{
  "parsing": {
    "nextPage": "a.next-page",  // 实际的选择器
    // 或其他可能的结构
    "nextPage": ".pagination a[aria-label='Next']",
    "nextPage": "a[href*='/page/']:contains('›')"
  }
}
```

**情况 B：分页 URL 格式变化**
如果网站改用查询参数分页（如 `?page=2`），需要修改 `MediaService.swift`：

```swift
// 在 parseNextPagePath 中处理查询参数分页
if let match = html.range(of: #"href="([^"]*\?page=\d+[^"]*)""#, options: .regularExpression) {
    // 提取并处理查询参数格式
}
```

**情况 C：无限滚动加载**
如果网站改用 JavaScript 无限滚动，需要：

- 移除 `nextPage` 选择器（返回 nil）
- 或实现特殊的 API 调用逻辑

### 实现细节

#### 文件修改清单

**1. DataSourceProfile.json（规则库）**
位置：https://github.com/jipika/WallHaven-Profiles/DataSourceProfile.json

需要根据实际网站结构更新：

```
{
  "parsing": {
    "nextPage": "正确的选择器"  // 待确认
  }
}
```

**2. MediaService.swift（诊断增强）**
位置：/Volumes/mac/CodeLibrary/Claude/WallHaven/Services/MediaService.swift

- 第 348-380 行：`parseNextPagePath` 函数
- 添加更详细的日志输出
- 改进分页链接的提取逻辑

**3. MediaServiceDiagnostic.swift（诊断工具）**
位置：/Volumes/mac/CodeLibrary/Claude/WallHaven/Diagnostics/MediaServiceDiagnostic.swift

- 添加分页链接检测
- 输出所有可能的分页元素

### 测试验证

1. 运行诊断脚本，检查分页链接提取
2. 在 App 中测试首页加载和下一页加载
3. 验证不同路由的分页（home、tag、search）

## Agent Extensions

### SubAgent

- **code-explorer**
- Purpose: 深入探索 MediaService 和相关服务的实现细节，查找分页逻辑的完整调用链
- Expected outcome: 确认分页失败的根本原因，定位所有需要修改的代码位置