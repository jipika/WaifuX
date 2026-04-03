# Tasks

- [x] Task 1: 修复验证码检测逻辑
  - [x] SubTask 1.1: 修改 `AnimeParser.swift` 中 `searchWithRule` 方法，仅在 `antiCrawlerConfig.enabled = true` 时检测验证码
  - [x] SubTask 1.2: 修改 `AnimeParser.swift` 中 `querychapterRoads` 方法，仅在 `antiCrawlerConfig.enabled = true` 时检测验证码
  - [x] SubTask 1.3: 移除 `detectCommonCaptcha` 的调用（保留方法供未来扩展）

- [x] Task 2: 补全 AntiCrawlerConfig 字段
  - [x] SubTask 2.1: 在 `AnimeRule.swift` 中添加 `captchaType` 和 `captchaInput` 字段
  - [x] SubTask 2.2: 更新 `KazumiRuleLoader.swift` 中的规则转换逻辑

- [x] Task 3: 修复规则字段映射
  - [x] SubTask 3.1: 检查 `chapterRoads` 和 `chapterResult` 的映射是否正确
  - [x] SubTask 3.2: 确保 `xpath.detail.episodes` 和 `xpath.list.list` 正确对应

- [x] Task 4: 对齐 XPath 解析行为
  - [x] SubTask 4.1: 检查 `HTMLXPathParser.swift` 中的相对 XPath 转换逻辑
  - [x] SubTask 4.2: 确保与 Kazumi 的 `xpath_selector_html_parser` 行为一致

- [x] Task 5: 测试验证
  - [x] SubTask 5.1: 测试不需要验证码的源能正常搜索和解析
  - [x] SubTask 5.2: 测试需要验证码的源正确触发验证流程
  - [x] SubTask 5.3: 测试剧集列表能正确解析

# Task Dependencies
- [Task 2] depends on [Task 1] (字段补全后才能完整测试验证码逻辑)
- [Task 5] depends on [Task 1, Task 2, Task 3, Task 4]
