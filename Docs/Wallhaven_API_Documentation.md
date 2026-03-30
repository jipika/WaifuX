# Wallhaven API 接口文档

> 基于 Wallhaven 官方 `API v1` 页面与 2026-03-25 实测结果整理
> 基础 URL: `https://wallhaven.cc/api/v1`
> 官方文档: https://wallhaven.cc/help/api

---

## 接口概览

Wallhaven API 是一套以只读能力为主的 REST API，适合做：

- 壁纸搜索与列表浏览
- 单张壁纸详情读取
- 标签信息读取
- 用户设置读取
- 公开/私有收藏夹读取

当前公开文档没有提供创建、更新、删除类写操作接口。

| 功能 | 方法 | 端点 | 说明 |
|------|------|------|------|
| 搜索壁纸 | GET | `/search` | 主入口，支持筛选/分页/随机/热门 |
| 壁纸详情 | GET | `/w/{id}` | 获取单张壁纸详情 |
| 标签详情 | GET | `/tag/{id}` | 获取标签信息 |
| 用户设置 | GET | `/settings` | 需 API Key |
| 收藏夹列表 | GET | `/collections` | 读取自己的收藏夹，需 API Key |
| 公开收藏夹列表 | GET | `/collections/{username}` | 读取其他用户公开收藏夹 |
| 收藏夹内容 | GET | `/collections/{username}/{id}` | 返回某收藏夹内的壁纸列表 |

---

## 认证方式

Wallhaven 支持两种认证方式：

### 1. 查询参数

```http
GET /api/v1/search?apikey=YOUR_API_KEY
```

### 2. 请求头

```http
X-API-Key: YOUR_API_KEY
```

在客户端里更推荐请求头方式，避免把 API Key 直接暴露在 URL 日志中。

### API Key 的作用

- 访问 `Sketchy` / `NSFW` 内容
- 读取 `/settings`
- 读取自己的私有收藏夹
- 按账号默认浏览设置执行搜索

未携带有效 API Key 访问受限内容时，接口会返回 `401 Unauthorized`。

---

## 搜索接口

### 请求

```http
GET https://wallhaven.cc/api/v1/search
```

### 常用参数

| 参数 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `q` | String | 搜索语句 | `nature` |
| `categories` | String | 三位分类开关 | `111` |
| `purity` | String | 三位纯度开关 | `100` |
| `sorting` | String | 排序方式 | `date_added` |
| `order` | String | 排序方向 | `desc` |
| `topRange` | String | 热榜时间范围，仅 `sorting=toplist` 生效 | `1M` |
| `atleast` | String | 最低分辨率 | `1920x1080` |
| `resolutions` | String | 精确分辨率列表，逗号分隔 | `1920x1080,2560x1440` |
| `ratios` | String | 比例列表，逗号分隔，使用 `x` | `16x9,21x9` |
| `colors` | String | 单个颜色过滤值 | `660000` |
| `page` | Integer | 页码 | `2` |
| `seed` | String | 随机排序时使用的种子 | `abc123` |

### `q` 支持的语法

- `tagname`：模糊搜索标签/关键词
- `-tagname`：排除关键词
- `+tag1 +tag2`：必须包含多个标签
- `+tag1 -tag2`：必须包含、必须排除组合
- `@username`：按上传者搜索
- `id:123`：按标签 ID 精确搜索，不能与其它条件组合
- `type:png` / `type:jpg`：按文件类型搜索
- `like:abcd12`：按某张壁纸的标签相似度搜索

### 分类参数 `categories`

三位字符串，每位分别代表：

| 位 | 含义 |
|----|------|
| 第 1 位 | General |
| 第 2 位 | Anime |
| 第 3 位 | People |

示例：

- `111`：全部分类
- `100`：仅 General
- `010`：仅 Anime
- `101`：General + People

### 纯度参数 `purity`

三位字符串，每位分别代表：

| 位 | 含义 | 是否需要 API Key |
|----|------|------------------|
| 第 1 位 | SFW | 否 |
| 第 2 位 | Sketchy | 是 |
| 第 3 位 | NSFW | 是 |

示例：

- `100`：仅 SFW
- `110`：SFW + Sketchy
- `111`：全部纯度

### 排序参数 `sorting`

支持以下值：

- `date_added`
- `relevance`
- `random`
- `views`
- `favorites`
- `toplist`

### `topRange`

仅在 `sorting=toplist` 时有效：

- `1d`
- `3d`
- `1w`
- `1M`
- `3M`
- `6M`
- `1y`

### 搜索示例

```http
GET /api/v1/search?q=cyberpunk&categories=010&purity=100
GET /api/v1/search?sorting=toplist&topRange=1M
GET /api/v1/search?sorting=random&seed=abc123&page=2
GET /api/v1/search?ratios=16x9,21x9&resolutions=2560x1440,3840x2160
GET /api/v1/search?colors=0066cc
```

### 搜索响应

每页固定返回 `24` 条，响应包含 `meta` 分页信息。

```json
{
  "data": [
    {
      "id": "yqg76d",
      "url": "https://wallhaven.cc/w/yqg76d",
      "short_url": "https://whvn.cc/yqg76d",
      "views": 5,
      "favorites": 0,
      "source": "",
      "purity": "sfw",
      "category": "general",
      "dimension_x": 2160,
      "dimension_y": 1920,
      "resolution": "2160x1920",
      "ratio": "1.13",
      "file_size": 1087795,
      "file_type": "image/jpeg",
      "created_at": "2026-03-24 07:53:00",
      "colors": ["#424153", "#333399", "#000000"],
      "path": "https://w.wallhaven.cc/full/yq/wallhaven-yqg76d.jpg",
      "thumbs": {
        "large": "https://th.wallhaven.cc/lg/yq/yqg76d.jpg",
        "original": "https://th.wallhaven.cc/orig/yq/yqg76d.jpg",
        "small": "https://th.wallhaven.cc/small/yq/yqg76d.jpg"
      }
    }
  ],
  "meta": {
    "current_page": 1,
    "last_page": 36,
    "per_page": 24,
    "total": 848,
    "query": "cyberpunk",
    "seed": null
  }
}
```

### 关于随机结果

Wallhaven 没有公开文档里的独立 `/random` API。

正确做法是：

```http
GET /api/v1/search?sorting=random
```

当 `sorting=random` 时，响应 `meta.seed` 会返回一个随机种子。翻下一页时继续携带同一个 `seed`，可以减少跨页重复。

---

## 壁纸详情接口

### 请求

```http
GET https://wallhaven.cc/api/v1/w/{id}
```

### 示例

```http
GET /api/v1/w/yqg76d
GET /api/v1/w/yqg76d?apikey=YOUR_API_KEY
```

### 特点

详情接口相比搜索项通常会多出：

- `uploader`
- `tags`
- 某些情况下的 `downloads`

### 响应示例

```json
{
  "data": {
    "id": "yqg76d",
    "url": "https://wallhaven.cc/w/yqg76d",
    "short_url": "https://whvn.cc/yqg76d",
    "uploader": {
      "username": "test-user",
      "group": "User",
      "avatar": {
        "200px": "https://wallhaven.cc/images/user/avatar/200/example.png",
        "128px": "https://wallhaven.cc/images/user/avatar/128/example.png",
        "32px": "https://wallhaven.cc/images/user/avatar/32/example.png",
        "20px": "https://wallhaven.cc/images/user/avatar/20/example.png"
      }
    },
    "views": 12,
    "favorites": 0,
    "purity": "sfw",
    "category": "anime",
    "dimension_x": 6742,
    "dimension_y": 3534,
    "resolution": "6742x3534",
    "ratio": "1.91",
    "file_size": 5070446,
    "file_type": "image/jpeg",
    "created_at": "2018-10-31 01:23:10",
    "colors": ["#000000", "#abbcda", "#424153"],
    "path": "https://w.wallhaven.cc/full/94/wallhaven-94x38z.jpg",
    "thumbs": {
      "large": "https://th.wallhaven.cc/lg/94/94x38z.jpg",
      "original": "https://th.wallhaven.cc/orig/94/94x38z.jpg",
      "small": "https://th.wallhaven.cc/small/94/94x38z.jpg"
    },
    "tags": [
      {
        "id": 1,
        "name": "anime",
        "alias": "Chinese cartoons"
      }
    ]
  }
}
```

---

## 标签接口

### 请求

```http
GET https://wallhaven.cc/api/v1/tag/{id}
```

### 响应示例

```json
{
  "data": {
    "id": 1,
    "name": "anime",
    "alias": "Chinese cartoons",
    "category_id": 1,
    "category": "Anime & Manga",
    "purity": "sfw",
    "created_at": "2015-01-16 02:06:45"
  }
}
```

---

## 用户设置接口

### 请求

```http
GET https://wallhaven.cc/api/v1/settings
```

必须携带有效 API Key。

### 响应示例

```json
{
  "data": {
    "thumb_size": "orig",
    "per_page": "24",
    "purity": ["sfw", "sketchy", "nsfw"],
    "categories": ["general", "anime", "people"],
    "resolutions": ["1920x1080", "2560x1440"],
    "aspect_ratios": ["16x9"],
    "toplist_range": "6M",
    "tag_blacklist": ["blacklist tag"],
    "user_blacklist": [""]
  }
}
```

---

## 收藏夹接口

### 读取自己的收藏夹

```http
GET https://wallhaven.cc/api/v1/collections
```

必须携带 API Key。

### 读取某个用户的公开收藏夹

```http
GET https://wallhaven.cc/api/v1/collections/{username}
```

### 读取收藏夹中的壁纸

```http
GET https://wallhaven.cc/api/v1/collections/{username}/{id}
```

该接口返回形态与 `/search` 很接近，但仅支持 `purity` 过滤。

### 收藏夹列表示例

```json
{
  "data": [
    {
      "id": 15,
      "label": "Default",
      "views": 38,
      "public": 1,
      "count": 10
    }
  ]
}
```

---

## 图片地址规则

### 缩略图

```text
https://th.wallhaven.cc/{size}/{prefix}/{id}.jpg
```

其中：

- `size=small`
- `size=lg`
- `size=orig`

实际项目里优先直接使用响应中的 `thumbs.small / thumbs.large / thumbs.original`，不要手写拼接。

### 原图

```text
https://w.wallhaven.cc/full/{prefix}/wallhaven-{id}.{ext}
```

例如：

```text
https://w.wallhaven.cc/full/yq/wallhaven-yqg76d.jpg
```

注意原图文件名包含 `wallhaven-` 前缀。

---

## 错误与限流

### 限流

官方文档当前说明为：

- `45` 次请求 / 分钟

超过限制时返回：

```http
429 Too Many Requests
```

### 常见状态码

| 状态码 | 说明 |
|--------|------|
| `200` | 请求成功 |
| `401` | API Key 无效、缺失，或访问了受限内容 |
| `404` | 资源不存在 |
| `429` | 请求过快 |

---

## Swift 接入建议

```swift
import Foundation

struct WallhavenSearchParameters {
    var query: String = ""
    var page: Int = 1
    var categories: String = "111"
    var purity: String = "100"
    var sorting: String = "date_added"
    var order: String = "desc"
}

func makeSearchRequest(parameters: WallhavenSearchParameters, apiKey: String?) -> URLRequest? {
    var components = URLComponents(string: "https://wallhaven.cc/api/v1/search")
    components?.queryItems = [
        URLQueryItem(name: "q", value: parameters.query),
        URLQueryItem(name: "page", value: String(parameters.page)),
        URLQueryItem(name: "categories", value: parameters.categories),
        URLQueryItem(name: "purity", value: parameters.purity),
        URLQueryItem(name: "sorting", value: parameters.sorting),
        URLQueryItem(name: "order", value: parameters.order)
    ]

    guard let url = components?.url else { return nil }

    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    if let apiKey, !apiKey.isEmpty {
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
    }

    return request
}
```

### 工程实践建议

- 搜索页优先用 `/search`，详情页再请求 `/w/{id}`
- 缩略图用 `thumbs.large/small`，下载原图再用 `path`
- `ratios` 参数用 `16x9` 这种格式，不要用 `16:9`
- `colors` 当前按官方文档应视为单值过滤
- 处理 `429` 时建议加退避重试
- 不要依赖独立 `/random` 端点，改用 `sorting=random`

---

*文档版本: 2.0*  
*最后更新: 2026-03-25*  
*基于 Wallhaven API v1 官方页面与公开接口实测整理*
