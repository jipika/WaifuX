# Checklist

## 验证码检测
- [x] `searchWithRule` 方法仅在 `antiCrawlerConfig.enabled = true` 时检测验证码
- [x] `querychapterRoads` 方法仅在 `antiCrawlerConfig.enabled = true` 时检测验证码
- [x] 不需要验证码的源不再误报验证码错误

## AntiCrawlerConfig 字段
- [x] `AntiCrawlerConfig` 包含 `captchaType` 字段
- [x] `AntiCrawlerConfig` 包含 `captchaInput` 字段
- [x] Kazumi 规则能正确解析所有反爬虫配置字段

## 规则映射
- [x] `chapterRoads` 正确映射到 `xpath.detail.episodes`
- [x] `chapterResult` 正确映射到 `xpath.list.list`
- [x] 剧集列表解析不再返回空结果

## XPath 解析
- [x] 相对 XPath 转换与 Kazumi 行为一致
- [x] 搜索结果能正确解析
- [x] 剧集列表能正确解析

## 整体功能
- [x] 动漫搜索功能正常
- [x] 剧集列表解析正常
- [x] 验证码流程正常触发
- [x] 编译成功
