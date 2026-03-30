# MoeWalls API 接口文档

> 本文档基于网页 HTML 结构分析编写
> 基础 URL: `https://moewalls.com`
> 站点类型: WordPress (Bimber主题) + Video.js
> 内容类型: Live Wallpapers (动态壁纸/视频壁纸)

---

## 目录

1. [接口概览](#接口概览)
2. [列表接口](#列表接口)
3. [搜索接口](#搜索接口)
4. [分类接口](#分类接口)
5. [详情接口](#详情接口)
6. [分页机制](#分页机制)
7. [数据结构](#数据结构)
8. [HTML 解析参考](#html-解析参考)

---

## 接口概览

MoeWalls 是一个 WordPress 站点，没有提供官方 REST API。所有数据需要通过 **HTML 解析 (Web Scraping)** 获取。

| 功能 | 方法 | URL 模式 | 说明 |
|------|------|----------|------|
| 获取首页列表 | GET | `/` 或 `/page/{page}/` | 获取最新壁纸列表 |
| 搜索 | GET | `/?s={keyword}` | 按关键词搜索 |
| 分类浏览 | GET | `/{category}/` | 按分类浏览 (如 anime, games) |
| 获取详情 | GET | `/{category}/{slug}/` | 获取单个壁纸详情 |

---

## 列表接口

### 请求

```http
GET https://moewalls.com/page/{page}/
```

### 参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| page | Integer | 否 | 页码，从 1 开始，默认 1 |

### 示例

```http
GET https://moewalls.com/
GET https://moewalls.com/page/2/
GET https://moewalls.com/page/3/
```

### 响应 (HTML)

返回 WordPress 生成的 HTML 页面，壁纸列表包含在以下结构中：

```html
<ul class="g1-collection-items">
  <li class="g1-collection-item g1-collection-item-1of3">
    <div class="entry-featured-media">
      <a class="g1-frame" href="https://moewalls.com/fantasy/gothic-cathedral-live-wallpaper/">
        <img src="https://moewalls.com/wp-content/uploads/2026/03/gothic-cathedral-thumb-364x205.jpg" />
      </a>
    </div>
    <h3 class="g1-gamma g1-gamma-1st entry-title">
      <a href="https://moewalls.com/fantasy/gothic-cathedral-live-wallpaper/">Gothic Cathedral Live Wallpaper</a>
    </h3>
  </li>
</ul>
```

---

## 搜索接口

### 请求

```http
GET https://moewalls.com/?s={keyword}
GET https://moewalls.com/page/{page}/?s={keyword}
```

### 参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| s | String | 是 | 搜索关键词 |
| page | Integer | 否 | 页码 |

### 示例

```http
GET https://moewalls.com/?s=gothic
GET https://moewalls.com/page/2/?s=anime
```

### 响应 (HTML)

搜索结果页面使用与首页相同的列表结构：

```html
<ul class="g1-collection-items">
  <li class="g1-collection-item g1-collection-item-1of3">
    <!-- 壁纸卡片内容 -->
  </li>
</ul>
```

**空结果标识:**

```html
<p class="no-results">No results found.</p>
```

---

## 分类接口

### 请求

```http
GET https://moewalls.com/{category}/
GET https://moewalls.com/{category}/page/{page}/
```

### 已知分类

| 分类名 | URL | 说明 |
|--------|-----|------|
| Anime | `/anime/` | 动漫 |
| Games | `/games/` | 游戏 |
| Fantasy | `/fantasy/` | 幻想 |
| Nature | `/nature/` | 自然 |
| Abstract | `/abstract/` | 抽象 |

### 示例

```http
GET https://moewalls.com/anime/
GET https://moewalls.com/games/page/2/
```

---

## 详情接口

### 请求

```http
GET https://moewalls.com/{category}/{slug}/
```

### 示例

```http
GET https://moewalls.com/fantasy/gothic-cathedral-live-wallpaper/
```

### 响应 (HTML)

详情页包含以下关键信息：

#### 1. 视频播放器 (预览)

```html
<video id="player_1463399730"
       class="video-js vjs-default-skin vjs-big-play-centered"
       poster="/wp-content/uploads/2026/03/gothic-cathedral-thumb-728x410.jpg">
  <source src="/wp-content/uploads/preview/2026/gothic-cathedral-preview.webm"
          type="video/mp4" />
</video>
```

#### 2. 标签/关键词

```html
<meta property="article:tag" content="Building" />
<meta property="article:tag" content="Cathedral" />
<meta property="article:tag" content="Dark" />
```

或在 JSON-LD 中：

```json
{
  "keywords": ["Building", "Castle", "Cathedral", "Dark", "Gothic"],
  "articleSection": ["Fantasy"]
}
```

#### 3. 缩略图 (高清)

```html
<meta property="og:image" content="https://moewalls.com/wp-content/uploads/2026/03/gothic-cathedral-thumb.jpg" />
```

#### 4. 发布日期

```html
<meta property="article:published_time" content="2026-03-24T09:53:12+00:00" />
```

---

## 分页机制

### HTML 结构

```html
<div class="pagination loop-pagination">
  <span aria-current="page" class="page-numbers current">1</span>
  <a class="page-numbers" href="https://moewalls.com/page/2/">2</a>
  <a class="page-numbers" href="https://moewalls.com/page/3/">3</a>
  <span class="page-numbers dots">…</span>
  <a class="next page-numbers" href="https://moewalls.com/page/2/">Next →</a>
</div>
```

### 总页数获取

从分页区域提取最大页码：

```python
# 示例：Python BeautifulSoup
pagination = soup.select_one('div.pagination.loop-pagination')
page_links = pagination.select('a.page-numbers')
last_page = max([int(link.text) for link in page_links if link.text.isdigit()])
```

---

## 数据结构

### MediaItem (列表项)

| 字段 | 类型 | 说明 | CSS 选择器 |
|------|------|------|-----------|
| title | String | 壁纸标题 | `h3.entry-title a` |
| slug | String | URL 标识符 | 从 `href` 提取 |
| pageURL | String | 详情页链接 | `h3.entry-title a[href]` |
| thumbnailURL | String | 缩略图地址 | `a.g1-frame img[src]` |
| category | String | 分类名 | 从 `href` 提取 (如 `/anime/`) |
| resolutionLabel | String | 分辨率标签 | 需从详情页获取 |

### MediaDetail (详情页)

| 字段 | 类型 | 说明 | CSS 选择器/属性 |
|------|------|------|-----------------|
| title | String | 完整标题 | `h1.entry-title` |
| previewVideoURL | String | 预览视频地址 | `video source[src]` |
| posterURL | String | 海报/缩略图 | `video[poster]` |
| tags | [String] | 标签列表 | `meta[property="article:tag"]` |
| category | String | 分类 | JSON-LD `articleSection` |
| publishedAt | DateTime | 发布时间 | `meta[property="article:published_time"]` |
| description | String | 描述 | `meta[name="description"]` |

---

## HTML 解析参考

### Python (BeautifulSoup)

```python
from bs4 import BeautifulSoup
import requests

# 获取列表
def fetch_list(page=1):
    url = f"https://moewalls.com/page/{page}/" if page > 1 else "https://moewalls.com/"
    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
    }
    response = requests.get(url, headers=headers)
    soup = BeautifulSoup(response.text, 'html.parser')

    items = []
    for li in soup.select('li.g1-collection-item.g1-collection-item-1of3'):
        # 跳过广告注入项
        if 'g1-injected-unit' in li.get('class', []):
            continue

        title_elem = li.select_one('h3.entry-title a')
        img_elem = li.select_one('a.g1-frame img')

        if title_elem and img_elem:
            items.append({
                'title': title_elem.text.strip(),
                'pageURL': title_elem['href'],
                'thumbnailURL': img_elem['src']
            })

    return items

# 获取详情
def fetch_detail(url):
    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
    }
    response = requests.get(url, headers=headers)
    soup = BeautifulSoup(response.text, 'html.parser')

    video_elem = soup.select_one('video.video-js source')
    poster_elem = soup.select_one('video.video-js')

    return {
        'previewVideoURL': video_elem['src'] if video_elem else None,
        'posterURL': poster_elem['poster'] if poster_elem else None,
        'tags': [tag['content'] for tag in soup.select('meta[property="article:tag"]')]
    }
```

### Swift (SwiftSoup)

```swift
import SwiftSoup

// 解析列表
func parseList(html: String) throws -> [MediaItem] {
    let doc = try SwiftSoup.parse(html)
    let items = try doc.select("li.g1-collection-item.g1-collection-item-1of3")

    return try items.compactMap { li -> MediaItem? in
        // 跳过广告
        if try li.classNames().contains("g1-injected-unit") {
            return nil
        }

        guard let titleElem = try li.select("h3.entry-title a").first(),
              let imgElem = try li.select("a.g1-frame img").first(),
              let title = try? titleElem.text(),
              let pageURL = try? titleElem.attr("href"),
              let thumbnailURL = try? imgElem.attr("src") else {
            return nil
        }

        return MediaItem(
            title: title,
            pageURL: URL(string: pageURL)!,
            thumbnailURL: URL(string: thumbnailURL)!
        )
    }
}

// 解析详情
func parseDetail(html: String) throws -> MediaDetail {
    let doc = try SwiftSoup.parse(html)

    let videoElem = try doc.select("video.video-js source").first()
    let posterElem = try doc.select("video.video-js").first()
    let previewURL = try videoElem?.attr("src")
    let posterURL = try posterElem?.attr("poster")

    return MediaDetail(
        previewVideoURL: previewURL != nil ? URL(string: previewURL!) : nil,
        posterURL: posterURL != nil ? URL(string: posterURL!) : nil
    )
}
```

---

## 注意事项

### 1. Cloudflare 保护

MoeWalls 使用了 Cloudflare CDN，可能会遇到：
- 503 Service Unavailable (JavaScript Challenge)
- 需要设置合理的 User-Agent

**建议:**
- 使用真实浏览器 User-Agent
- 添加延迟，避免高频请求
- 考虑使用 cloudscraper 等库

### 2. 反爬虫措施

- 检测异常的请求频率
- 可能需要处理 Cookie

### 3. 广告过滤

列表中可能包含广告项，特征为：
- `class` 包含 `g1-injected-unit`
- 缺少 `h3.entry-title` 子元素

### 4. 视频格式

- 预览视频通常为 `.webm` 格式
- 完整下载可能需要点击下载按钮获取外链

---

## 错误处理

| HTTP 状态码 | 说明 |
|-------------|------|
| 200 | 成功 |
| 404 | 页面/壁纸不存在 |
| 503 | Cloudflare 验证 |
| 429 | 请求过于频繁 |

---

*文档版本: 1.0*
*最后更新: 2026-03-25*
*基于网页分析编写*
