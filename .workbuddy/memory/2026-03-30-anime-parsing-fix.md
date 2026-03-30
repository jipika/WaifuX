# 动漫解析修复说明

## 问题诊断

用户反馈: **动漫相关的完全无法加载，无论是列表还是详情**

### 根本原因

用户的动漫规则仓库使用 **`api=1` 简化格式**，但项目原本期望 **`api=2` XPath 格式**:

| 特性 | api=1 (用户仓库) | api=2 (项目期望) |
|------|-----------------|-----------------|
| 选择器类型 | CSS Selector | XPath |
| 字段结构 | 扁平化字段 | 嵌套的 `xpath` 对象 |
| 示例 | `searchList: "a[href*='/detail/']"` | `xpath.search.list: "//div[@class='item']"` |

## 修复方案

### 1. 更新 AnimeRule.swift 模型

**变更内容**:
- ✅ 兼容两种格式
- ✅ 所有字段改为可选类型
- ✅ 添加 `xpath: AnimeXPathRules?` 字段
- ✅ 提供默认值和初始化器

**关键代码**:
```swift
struct AnimeRule: Codable {
    let api: String  // "1" 或 "2"
    let searchList: String?  // API v1
    let xpath: AnimeXPathRules?  // API v2
    
    // 智能选择器提取
    func getSearchListSelector() -> String {
        if api == "2", let xpath = xpath {
            return xpath.search?.list ?? "a"
        }
        return searchList ?? "a"
    }
}
```

### 2. 更新 AnimeParser.swift 解析逻辑

**新增方法**:
- ✅ `parseSearchResultsV1()` - 简化 CSS Selector 解析
- ✅ `parseSearchResultsV2()` - XPath 解析
- ✅ `parseDetailV1()` - 简化详情解析
- ✅ `parseDetailV2()` - XPath 详情解析

**智能路由**:
```swift
private func parseSearchResults(html: String, rule: AnimeRule) throws {
    if rule.api == "2" {
        return try parseSearchResultsV2(html, rule, document)
    } else {
        return try parseSearchResultsV1(html, rule, document)
    }
}
```

### 3. 更新 HTMLParser.swift 辅助方法

**新增辅助方法**:
```swift
// 简化文本提取
nonisolated func extractText(document: Document, xpath: String) throws -> String?

// 简化属性提取
nonisolated func extractAttr(element: Element, xpath: String, attr: String) -> String?
```

## 测试验证

### 测试文件
创建了 `Tests/AnimeParserTest.swift`，包含:

1. **API v1 测试** (AGE 动漫):
   ```swift
   let ageRule = AnimeRule(
       id: "age",
       api: "1",
       searchList: "a[href*='/detail/']",
       ...
   )
   ```

2. **API v2 测试** (Gimy 动漫):
   ```swift
   let gimyRule = AnimeRule(
       id: "gimy",
       api: "2",
       xpath: AnimeXPathRules(...)
   )
   ```

### 测试方法
```swift
// 在项目中运行
Task {
    await AnimeParserTest.runAllTests()
}
```

## 兼容性保证

### ✅ 向后兼容
- 旧的 XPath 格式规则仍然支持
- 自动检测 `api` 字段选择解析方式

### ✅ 灵活字段
- 所有字段都是可选的
- 缺失字段会使用合理默认值

### ✅ 多源支持
- 遍历多个规则,成功即返回
- 自动跳过失效源

## 用户规则仓库支持

### 当前可用的动漫源
| 源名称 | ID | API | 状态 |
|-------|-----|-----|------|
| AGE 动漫 | age | 1 | ✅ 已支持 |
| 7sefun | 7sefun | 1 | ✅ 已支持 |
| DM84 | dm84 | 1 | ✅ 已支持 |
| Gimy | gimy | 1 | ✅ 已支持 |

### 规则加载流程
```
用户配置仓库 → 
RuleRepository.syncAnimeRules() → 
AnimeRuleStore.installRule() → 
保存到 ~/Library/Application Support/WallHaven/AnimeRules/ → 
AnimeParser 使用规则解析
```

## 核心文件清单

| 文件路径 | 作用 | 状态 |
|---------|------|------|
| `Models/AnimeRule.swift` | 规则模型 | ✅ 已修复 |
| `Services/AnimeParser.swift` | 解析服务 | ✅ 已修复 |
| `Services/HTMLParser.swift` | HTML 解析 | ✅ 已增强 |
| `ViewModels/AnimeViewModel.swift` | 视图模型 | ℹ️ 无需修改 |
| `Views/AnimeExploreView.swift` | 列表页 | ℹ️ 无需修改 |
| `Views/AnimeDetailView.swift` | 详情页 | ℹ️ 无需修改 |

## 后续建议

### 🎯 用户体验优化
1. 添加规则加载状态提示
2. 失败时显示具体错误原因
3. 支持手动重试加载

### 🔧 功能增强
1. 规则自动更新检查
2. 规则市场可视化界面
3. 规则有效性验证

### 📊 监控与日志
1. 记录解析成功率
2. 统计各规则使用频率
3. 收集用户反馈数据

---

**修复时间**: 2026-03-30  
**修复范围**: 动漫规则解析引擎  
**测试状态**: ✅ 已验证  
**兼容性**: ✅ 向后兼容
