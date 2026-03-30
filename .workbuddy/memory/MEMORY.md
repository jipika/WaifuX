# WallHaven 项目记忆

## 动漫解析修复 (2026-03-30)

### 问题
用户的动漫规则仓库 (https://github.com/jipika/WallHaven-Profiles) 使用 `api=1` 的简化格式,但项目原本期望 `api=2` 的 XPath 格式,导致动漫列表和详情页无法加载。

### 解决方案
1. **更新 AnimeRule.swift 模型**:
   - 兼容两种格式: `api=1` (简化 CSS Selector) 和 `api=2` (XPath)
   - 添加可选的 `xpath` 字段支持 Kazumi 格式
   - 所有字段改为可选类型,提供默认值

2. **更新 AnimeParser.swift**:
   - 新增 `parseSearchResultsV1()` 和 `parseSearchResultsV2()` 方法
   - 根据规则 `api` 字段自动选择解析方式
   - 支持 XPath 转 CSS Selector 的转换
   - 添加详细日志输出

3. **更新 HTMLParser.swift**:
   - 添加 `extractText()` 和 `extractAttr()` 辅助方法
   - 简化 XPath 和 CSS Selector 的提取逻辑

### 测试
- 创建了完整的测试套件:
  - `Tests/AnimeRuleDecodingTest.swift` - 模型解码测试
  - `Tests/AnimeParserIntegrationTest.swift` - 集成测试
  - `Tests/AnimeParserTests.swift` - 测试运行器
- 测试了 AGE 动漫源 (api=1) 和 Gimy 动漫源 (api=2)
- 列表和详情页加载功能正常

### Git 提交
- 提交哈希: `46523c5`
- 已推送到远程仓库: `https://github.com/jipika/WallHaven`
- 提交信息包含详细的修复说明和测试结果

### 规则仓库结构
```json
{
  "id": "age",
  "api": "1",
  "type": "anime",
  "name": "AGE 动漫",
  "searchURL": "https://www.agedm.io/search?query={keyword}",
  "searchList": "a[href*='/detail/']",
  "searchName": "a[href*='/detail/']",
  "searchCover": "img",
  ...
}
```

### 关键文件
- `/Models/AnimeRule.swift` - 动漫规则模型
- `/Services/AnimeParser.swift` - 动漫解析服务
- `/Services/HTMLParser.swift` - HTML 解析引擎
- `/ViewModels/AnimeViewModel.swift` - 动漫视图模型
- `/Views/AnimeExploreView.swift` - 动漫探索页面
- `/Views/AnimeDetailView.swift` - 动漫详情页
- `/Tests/` - 测试文件目录

### 注意事项
- 规则中的所有字段都是可选的,解析时会使用合理的默认值
- XPath 格式会被自动转换为 CSS Selector
- 支持多动漫源自动切换
- 日志输出已添加到关键解析步骤,便于调试
