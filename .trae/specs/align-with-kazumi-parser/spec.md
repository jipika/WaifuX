# 动漫解析器与 Kazumi 对齐 Spec

## Why

当前项目的动漫解析存在以下问题：
1. 有些规则解析不出来搜索结果
2. 有些明明不需要验证码的源却提示需要验证
3. 有些验证完成后集数没有正确解析

这些问题是因为当前实现与 Kazumi 参考实现存在差异，需要对齐。

## What Changes

### 1. 验证码检测逻辑修复
- **问题**: 当前项目无论 `antiCrawlerConfig.enabled` 是否为 true 都会检测常见验证码关键词
- **Kazumi 行为**: 只有当 `antiCrawlerConfig.enabled = true` 时才检测验证码
- **修复**: 修改 `AnimeParser.swift` 中的验证码检测逻辑，仅在 `antiCrawlerConfig.enabled = true` 时检测

### 2. AntiCrawlerConfig 字段补全
- **问题**: 缺少 `captchaType` 和 `captchaInput` 字段
- **Kazumi 行为**: 支持两种验证码类型（图片验证码、自动点击按钮）
- **修复**: 补全 `AntiCrawlerConfig` 结构体字段

### 3. 规则字段映射修复
- **问题**: `chapterRoads` 和 `chapterResult` 的映射可能导致解析失败
- **修复**: 检查并修复 `KazumiRuleLoader.swift` 中的字段映射

### 4. XPath 解析对齐
- **问题**: 相对 XPath 转换可能与 Kazumi 的 `xpath_selector_html_parser` 行为不一致
- **修复**: 确保 `HTMLXPathParser.swift` 的相对 XPath 转换与 Kazumi 一致

### 5. 搜索结果过滤逻辑对齐
- **问题**: 当前项目的搜索结果过滤可能过于激进
- **修复**: 对齐 Kazumi 的搜索结果过滤逻辑

## Impact

- Affected code:
  - `Services/AnimeParser.swift` - 验证码检测逻辑
  - `Models/AnimeRule.swift` - AntiCrawlerConfig 结构体
  - `Services/KazumiRuleLoader.swift` - 规则字段映射
  - `Services/HTMLXPathParser.swift` - XPath 解析逻辑

## ADDED Requirements

### Requirement: 验证码检测对齐 Kazumi

#### Scenario: 规则未启用反爬虫配置
- **WHEN** 规则的 `antiCrawlerConfig.enabled = false` 或未配置
- **THEN** 不检测验证码，直接返回解析结果

#### Scenario: 规则启用反爬虫配置
- **WHEN** 规则的 `antiCrawlerConfig.enabled = true`
- **AND** HTML 中匹配 `captchaImage` 或 `captchaButton` XPath
- **THEN** 抛出 `captchaRequired` 错误

### Requirement: AntiCrawlerConfig 字段完整支持

#### Scenario: 解析 Kazumi 规则
- **WHEN** 加载 Kazumi 格式的规则 JSON
- **THEN** 正确解析 `captchaType` 和 `captchaInput` 字段

### Requirement: 剧集列表解析对齐

#### Scenario: 使用 chapterRoads 解析剧集
- **WHEN** 规则包含 `chapterRoads` 和 `chapterResult` XPath
- **THEN** 正确解析剧集列表，不返回空结果

## MODIFIED Requirements

### Requirement: 搜索结果解析
- 移除过于激进的验证码关键词检测
- 仅在 `antiCrawlerConfig.enabled = true` 时检测验证码

## REMOVED Requirements

### Requirement: 通用验证码关键词检测
**Reason**: Kazumi 不使用通用关键词检测，仅依赖规则配置的 XPath 选择器
**Migration**: 删除 `detectCommonCaptcha` 方法的调用，保留方法供未来扩展
