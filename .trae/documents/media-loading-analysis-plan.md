# 媒体数据加载问题深度分析计划

## 问题概述
媒体相关数据无法正常加载，需要深度分析根本原因。

## 分析维度

### 1. 网络层分析
**目标文件**: [Services/NetworkService.swift](Services/NetworkService.swift)

**检查点**:
- URLCache 配置是否合理（当前：50MB 内存 + 200MB 磁盘）
- URLSession 超时设置（当前：30秒）
- 缓存策略（当前：returnCacheDataElseLoad）
- HTTP 请求头配置
- 网络错误处理机制

**潜在问题**:
- 缓存策略可能导致加载旧数据
- 超时时间可能不足以应对慢速网络
- 缺少网络状态检测
- 没有重试机制

### 2. 数据解析层分析
**目标文件**: [Services/MediaService.swift](Services/MediaService.swift)

**检查点**:
- 正则表达式匹配逻辑（listItemPatterns）
- HTML 解析流程
- 数据提取和转换
- 错误处理和日志记录

**关键代码段**:
```swift
// 第 178-184 行：正则表达式匹配
let regexes = listItemRegexes()
for (index, itemRegex) in regexes.enumerated() {
    let matches = itemRegex.matches(in: html, options: [], range: htmlNSRange)
    print("[MediaService] parseListPage: pattern \(index + 1) matched \(matches.count) items")
}
```

**潜在问题**:
- 正则表达式可能不匹配当前网站 HTML 结构
- HTML 结构变化导致解析失败
- 捕获组索引错误
- 编码问题（HTML 实体解码）

### 3. 配置文件分析
**目标文件**: [DataSourceProfile.json](DataSourceProfile.json), [Models/FavoriteSource.swift](Models/FavoriteSource.swift)

**检查点**:
- listItemPatterns 配置
- nextPagePatterns 配置
- tagPattern 配置
- downloadPattern 配置
- baseURL 和 headers 配置

**当前配置**:
```json
"listItemPatterns": [
  "<a title=\"([^\"]+)\" href=([^ >]+)>.*?<img[^>]+src=([^ >]+)[^>]*>.*?<span class=[\"']?ttl[\"']?>(.*?)</span>\\s*<span class=[\"']?frm[\"']?>\\s*(.*?)\\s*</span>",
  "<a[^>]*title=[\"']?([^\"'>]+)[\"']?[^>]*href=[\"']?([^\"'\\s>]+)[\"']?[^>]*>.*?<img[^>]+src=[\"']?([^\"'\\s>]+)[\"']?[^>]*>.*?<span[^>]*>([^<]*)</span>\\s*<span[^>]*>\\s*</span>\\s*<span[^>]*>([^<]*)</span>"
]
```

**潜在问题**:
- 正则表达式过于严格，无法适应 HTML 变化
- 引号处理不一致（有引号/无引号的 class 属性）
- 缺少对动态内容（JavaScript 渲染）的支持

### 4. 视图层分析
**目标文件**: [ViewModels/MediaExploreViewModel.swift](ViewModels/MediaExploreViewModel.swift), [Views/MediaExploreContentView.swift](Views/MediaExploreContentView.swift)

**检查点**:
- 数据加载触发时机
- 加载状态管理（isLoading, isLoadingMore）
- 错误状态处理
- UI 反馈机制

**关键代码段**:
```swift
// 第 79-118 行：load 方法
func load(source: MediaRouteSource) async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    
    do {
        await mediaService.clearCache()
        let page = try await mediaService.fetchPage(source: source)
        // ...
    } catch {
        errorMessage = error.localizedDescription
    }
}
```

**潜在问题**:
- 竞态条件（虽然使用了 atomic check）
- 错误信息不够详细
- 缺少重试机制
- 加载状态可能卡死

### 5. 诊断工具分析
**目标文件**: [Diagnostics/MediaServiceDiagnostic.swift](Diagnostics/MediaServiceDiagnostic.swift)

**现有诊断功能**:
- 网络请求测试
- 正则表达式匹配测试
- HTML 结构检查
- 完整解析流程模拟

**改进建议**:
- 添加更详细的错误诊断
- 支持实时网络状态检测
- 添加 HTML 结构变化检测
- 提供修复建议

## 根本原因假设

### 假设 1: 正则表达式不匹配
**可能性**: 高
**原因**: 
- 网站 HTML 结构可能已更新
- 正则表达式过于严格
- class 属性引号处理不一致

**验证方法**:
1. 获取实际 HTML 内容
2. 测试正则表达式匹配
3. 对比预期和实际 HTML 结构

### 假设 2: 网络请求被阻止
**可能性**: 中
**原因**:
- Cloudflare 防护
- User-Agent 检测
- 地理位置限制
- IP 封禁

**验证方法**:
1. 检查 HTTP 状态码
2. 检查返回内容是否包含验证页面
3. 测试不同的请求头

### 假设 3: 数据解析逻辑错误
**可能性**: 中
**原因**:
- 捕获组索引错误
- 数据转换失败
- 编码问题

**验证方法**:
1. 添加详细日志
2. 逐步验证每个解析步骤
3. 测试边界情况

### 假设 4: 配置文件问题
**可能性**: 低
**原因**:
- 配置文件格式错误
- 配置未正确加载
- 配置与代码不匹配

**验证方法**:
1. 验证 JSON 格式
2. 检查配置加载日志
3. 对比内置配置和实际使用配置

## 实施步骤

### 第一阶段：诊断数据收集
1. 运行现有诊断工具
2. 收集网络请求日志
3. 获取实际 HTML 内容
4. 测试正则表达式匹配

### 第二阶段：问题定位
1. 分析诊断结果
2. 确定失败的具体环节
3. 验证根本原因假设

### 第三阶段：修复方案设计
1. 针对确定的根本原因设计修复方案
2. 考虑多种修复策略
3. 评估修复风险

### 第四阶段：实施修复
1. 实施选定的修复方案
2. 添加必要的日志和监控
3. 测试修复效果

### 第五阶段：验证和优化
1. 全面测试修复效果
2. 优化性能和用户体验
3. 添加防护措施避免再次发生

## 预期产出

1. **问题诊断报告**: 详细说明问题根本原因
2. **修复代码**: 针对性的代码修复
3. **测试验证**: 确保修复有效的测试
4. **监控方案**: 防止问题再次发生的监控机制
5. **文档更新**: 更新相关文档和注释

## 时间估算

- 第一阶段（诊断）: 1-2 小时
- 第二阶段（定位）: 1 小时
- 第三阶段（设计）: 1 小时
- 第四阶段（实施）: 2-3 小时
- 第五阶段（验证）: 1 小时

**总计**: 6-8 小时

## 风险评估

1. **网站结构变化**: 如果网站完全重构，可能需要重新设计解析逻辑
2. **防护机制**: 如果遇到强防护，可能需要使用代理或其他方案
3. **性能影响**: 修复可能影响加载性能，需要权衡
4. **兼容性**: 修复可能影响其他功能，需要全面测试
