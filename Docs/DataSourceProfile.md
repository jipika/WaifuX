# Data Source Profile

本项目支持把壁纸接口、媒体接口和动漫接口抽象成可导入的配置文件。

设计目标：

- 内置一份默认配置，保证开箱即用
- 支持在设置页导入新的 JSON 配置
- 支持在多份配置间切换，便于测试不同接口
- 当页面异常时，可以先确认是页面状态问题还是接口配置问题
- 支持动漫解析（参考 Kazumi 插件格式）

## 参考来源

这个思路参考了 `venera` / `venera-configs` 和 `Kazumi` 的拆分方式：

- 主程序负责读取和执行配置
- 配置仓库负责分发可扩展的数据源定义

我们这里没有走 JS 运行时，而是采用更适合当前 Swift/macOS 项目的 JSON Profile 模式。

## 文件格式

### 1. 单个 Profile

```json
{
  “id”: “wallhaven-motionbgs-default”,
  “name”: “WallHaven + MotionBGs”,
  “description”: “Built-in default profile for the current app.”,
  “wallpaper”: {
    “provider”: “wallhaven_api”,
    “displayName”: “WallHaven”,
    “apiBaseURL”: “https://wallhaven.cc/api/v1”,
    “searchPath”: “/search”,
    “wallpaperPath”: “/w/{id}”,
    “imageURLTemplate”: “https://w.wallhaven.cc/full/{prefix}/wallhaven-{id}.{ext}”,
    “authHeaderName”: “X-API-Key”
  },
  “media”: {
    “provider”: “motionbgs_html”,
    “displayName”: “MotionBGs”,
    “baseURL”: “https://motionbgs.com”,
    “headers”: {
      “User-Agent”: “Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36”,
      “Accept-Language”: “en-US,en;q=0.9”
    },
    “routes”: {
      “home”: “/”,
      “mobile”: “/mobile/”,
      “tag”: “/tag:{slug}/”,
      “search”: “/search?q={query}”,
      “detail”: “/{slug}”
    },
    “parsing”: {
      “searchList”: “//div[contains(@class, 'flex flex-col')]/a”,
      “searchName”: “.//img/@alt”,
      “searchResult”: “@href”,
      “searchCover”: “.//img/@src”
    }
  },
  “anime”: null
}
```

### 2. 带动漫配置的 Profile

```json
{
  “id”: “anime-example”,
  “name”: “WallHaven + Anime”,
  “description”: “Profile with anime support”,
  “wallpaper”: { ... },
  “media”: { ... },
  “anime”: {
    “enabled”: true,
    “provider”: “age_html”,
    “displayName”: “AGE”,
    “baseURL”: “https://www.agedm.io”,
    “userAgent”: “”,
    “searchURL”: “https://www.agedm.io/search?query=@keyword”,
    “parsing”: {
      “searchList”: “//div[2]/div/section/div/div/div/div”,
      “searchName”: “//div/div[2]/h5/a”,
      “searchResult”: “//div/div[2]/h5/a”,
      “searchCover”: “//img/@src”,
      “chapterRoads”: “//div[2]/div/section/div/div[2]/div[2]/div[2]/div”,
      “chapterResult”: “//ul/li/a”,
      “chapterName”: “//text()”,
      “detailCover”: “//div[@class='cover']/img/@src”,
      “detailDescription”: “//div[@class='desc']/text()”
    }
  }
}
```

### 3. Profile Catalog

```json
{
  “schemaVersion”: “2.0.0”,
  “profiles”: [
    { ... }
  ]
}
```

## 占位符

以下字段支持占位符替换：

- `wallpaper.wallpaperPath`:
  - `{id}`
- `wallpaper.imageURLTemplate`:
  - `{prefix}`: 壁纸 ID 前两位
  - `{id}`
  - `{ext}`
- `media.routes.tag`:
  - `{slug}`
- `media.routes.search`:
  - `{query}`
- `media.routes.detail`:
  - `{slug}`
- `anime.searchURL`:
  - `@keyword`: 搜索关键词

## 设置页行为

设置页支持：

- 导入 JSON 配置
- 从 URL 导入配置
- 切换当前激活的 profile
- 恢复到内置默认配置
- 删除导入的 profile
- 测试数据源配置

内置默认配置不会被删除。

## 排障建议

当”媒体页 / 壁纸页 / 动漫页查不到数据”时，按这个顺序排查：

1. 先看当前激活的是不是正确的 profile
2. 检查 `baseURL` / `searchPath` / `searchURL` 是否仍然有效
3. 如果接口能返回 HTML/JSON，但页面为空：
   这更像是解析规则不匹配，例如：
   - `searchList` / `searchName` / `searchResult`
   - `chapterRoads` / `chapterResult`
4. 如果接口本身返回 403/404/5xx：
   这更像是站点规则、代理地址或接口路径发生变化

## 当前实现边界

当前 JSON 配置已经覆盖：

- 壁纸接口地址
- 壁纸图片模板
- 媒体页面路由模板
- 媒体核心 XPath 解析规则
- 请求头
- 动漫搜索和播放列表解析（参考 Kazumi 格式）

但它还不是一个”任意脚本驱动”的运行时系统。
也就是说：

- 适合接口地址、HTML 结构、分页规则的演进
- 适合动漫源的搜索和剧集列表解析
- 不适合完全陌生的新站点协议

如果后续要把第三方媒体源扩展到更多站点，可以在这个 Profile 体系上继续加 provider 类型。
