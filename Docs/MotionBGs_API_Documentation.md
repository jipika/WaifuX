# MotionBGs API Documentation

## 概述

MotionBGs (https://motionbgs.com) 是一个提供动态壁纸（Live Wallpaper）的网站，支持 PC (Windows/macOS) 和 Mobile 平台。WallHaven 应用通过解析 HTML 页面的方式获取数据。

**总壁纸数量**: 8780+ (持续增加)

---

## 数据源信息

| 项目 | 值 |
|------|-----|
| 基础 URL | `https://motionbgs.com` |
| User-Agent | `Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/53736` |
| Accept-Language | `en-US,en;q=0.9` |

---

## URL 结构完整解析

### 1. 列表页类型

| 类型 | URL 格式 | 说明 |
|------|----------|------|
| 首页 | `https://motionbgs.com/` | 全部壁纸（多区块混合） |
| 4K 壁纸 | `https://motionbgs.com/4k/` | 仅 4K 分辨率（可能有分页） |
| Mobile | `https://motionbgs.com/mobile/` | 移动端壁纸 |
| Gifs | `https://motionbgs.com/gifs/` | GIF 格式 |
| 标签页 | `https://motionbgs.com/tag:{slug}/` | 按标签分类 |

### 2. 分页系统（重要！）

#### 首页分页格式 `/hx2/latest/{page}/`

**这是网站实际使用的分页格式！**

| 页面 | URL |
|------|-----|
| 第1页 | `/hx2/latest/1/` |
| 第2页 | `/hx2/latest/2/` |
| 第3页 | `/hx2/latest/3/` |
| ... | ... |

分页参数 `{page}` 从 1 开始，每个页面约 30-40 个壁纸。

#### 标签页分页格式 `/tag:{slug}/{page}/`

| 标签 | 第1页 | 第2页 | 第3页 |
|------|-------|-------|-------|
| anime | `/tag:anime/` | `/tag:anime/2/` | `/tag:anime/3/` |
| goku | `/tag:goku/` | `/tag:goku/2/` | `/tag:goku/3/` |
| dragon-ball | `/tag:dragon-ball/` | `/tag:dragon-ball/2/` | `/tag:dragon-ball/3/` |

#### 搜索结果分页格式

搜索结果使用 Query Parameter 格式：`/search?q={query}&page={page}`

| 搜索词 | 第1页 | 第2页 | 第3页 |
|--------|-------|-------|-------|
| goku | `/search?q=goku` | `/search?q=goku&page=2` | `/search?q=goku&page=3` |
| naruto | `/search?q=naruto` | `/search?q=naruto&page=2` | `/search?q=naruto&page=3` |

#### 4K/Mobile/Gifs 列表分页格式

| 类型 | 第1页 | 第2页 | 说明 |
|------|-------|-------|------|
| 4K | `/4k/` | `/4k/2/` | 4K 分辨率 |
| Mobile | `/mobile/` | `/mobile/2/` | 移动端壁纸 |
| Gifs | `/gifs/` | `/gifs/2/` | GIF 格式 |

#### 分页识别总结表

| 来源类型 | URL 格式 | 正则匹配 | 分页参数提取 |
|----------|----------|----------|--------------|
| 首页 | `/hx2/latest/{page}/` | `#/hx2/latest/(\d+)/#` | `page` |
| 标签页 | `/tag:{slug}/{page}/` | `#/tag:([^/]+)/(\d+)/#` | `slug`, `page` |
| 搜索页 | `/search?q={q}&page={n}` | `#/search\?q=([^&]+)&page=(\d+)#` | `query`, `page` |
| 4K/Mobile/Gifs | `/{type}/{page}/` | `#/(4k\|mobile\|gifs)/(\d+)/#` | `type`, `page` |

### 3. 详情页

```
https://motionbgs.com/{slug}
```

例如：`https://motionbgs.com/wuthering-waves-arcane-clash`

### 4. 下载页

| 类型 | URL 格式 |
|------|----------|
| 4K 下载 | `https://motionbgs.com/dl/4k/{id}` |
| HD 下载 | `https://motionbgs.com/dl/hd/{id}` |

---

## 列表页数据结构

### 新版 HTML 结构（/hx2/latest/{page}/）

```html
<a title="{title}" href="/{slug}">
  <img src="...">
  <span>Title Text</span>
  <span> </span>
  <span>4K</span>
</a>
```

**正则表达式（新）：**
```swift
let listItemRegexNew = try! NSRegularExpression(
    pattern: #"<a title="([^"]+)" href="([^"]+)">.*?<img[^>]+src="([^"]+)"[^>]*>.*?<span[^>]*>([^<]*)</span>\s*<span[^>]*>\s*</span>\s*<span[^>]*>([^<]*)</span>"#,
    options: [.caseInsensitive, .dotMatchesLineSeparators]
)
// 捕获组：
// 1. title (标题)
// 2. href (路径，如 "/slug-name")
// 3. img src (缩略图 URL)
// 4. 标题文本
// 5. 分辨率标签（如 "4K"）
```

### 旧版 HTML 结构（/4k/ 等）

```html
<a title="{title}" href="/{slug}">
  <img src="...">
  <span class="ttl">{label}</span>
  <span class="frm">{resolution}</span>
</a>
```

**正则表达式（旧）：**
```swift
let listItemRegexOld = try! NSRegularExpression(
    pattern: #"<a title="([^"]+)" href=([^ >]+)>.*?<img[^>]+src=([^ >]+)[^>]*>.*?<span class=ttl>(.*?)</span>\s*<span class=frm>\s*(.*?)\s*</span>"#,
    options: [.caseInsensitive, .dotMatchesLineSeparators]
)
```

### 解析字段

| 字段 | 来源 | 说明 |
|------|------|------|
| slug | href 路径 | 提取路径最后一段 |
| title | title 或链接文本 | 清理后缀 |
| pageURL | href 拼接 baseURL | 完整页面 URL |
| thumbnailURL | img src | 缩略图 URL |
| resolutionLabel | span 文本 | 分辨率如 "4K", "HD" |

---

## 分页识别

### 通过 URL 直接判断分页

**这是最可靠的方式！直接解析 URL 即可获取页码和下一页路径：**

```swift
// 从 URL 提取分页信息的正则表达式

// 首页分页: /hx2/latest/{page}/
let homePaginationRegex = try! NSRegularExpression(
    pattern: #"/hx2/latest/(\d+)/"#,
    options: []
)

// 标签分页: /tag:{slug}/{page}/
let tagPaginationRegex = try! NSRegularExpression(
    pattern: #"/tag:([^/]+)/(\d+)/"#,
    options: []
)

// 搜索分页: /search?q={query}&page={page}
let searchPaginationRegex = try! NSRegularExpression(
    pattern: #"/search\?q=([^&]+)&page=(\d+)"#,
    options: []
)

// 4K/Mobile/Gifs 分页: /{type}/{page}/
let listPaginationRegex = try! NSRegularExpression(
    pattern: #"/(4k|mobile|gifs)/(\d+)/"#,
    options: []
)
```

### 通过 HTML 控件识别分页（备用方案）

当 URL 无法直接判断时，使用以下正则识别下一页链接：

```swift
// 1. <link rel="next" href="...">
"href\s*=\s*"?([^">\s]+)"?\s*(?=rel="?next"?)"

// 2. <section class="pag"> 格式
"<section[^>]*class=[\"']?pag[\"']?[^>]*>.*?<a[^>]*href=[\"']?([^\"'\s]+)[\"']?[^>]*>\s*Next"

// 3. "View More Wallpapers" 链接
"<div class=larrow><a class=link--arrowed href=([^ >\s]+)>\s*View More Wallpapers"

// 4. 通用 Next 链接
"<a[^>]*href=[\"']?([^\"'\s]+)[\"']?[^>]*>\s*Next\s*</a>"

// 5. Previous/Next 配对（标签页常用）
"<a[^>]*href=[\"']?([^\"'\s]+)[\"']?[^>]*>\s*Next\s*</a>"
```

### 实际分页示例

**首页 (`/hx2/latest/`):**
- 第1页: `https://motionbgs.com/hx2/latest/1/` → 下一页: `2/`
- 第2页: `https://motionbgs.com/hx2/latest/2/` → 下一页: `3/`, 上一页: `1/`
- 最后一页: 无 Next 链接

**标签页 (`/tag:{slug}/`):**
- 第1页: `https://motionbgs.com/tag:goku/` → 下一页: `2/`
- 第2页: `https://motionbgs.com/tag:goku/2/` → 下一页: `3/`, 上一页: 无 (首页无 Previous)
- 最后一页: 仅有 Previous 链接

**搜索页 (`/search?q=`):**
- 第1页: `https://motionbgs.com/search?q=goku` → 下一页: `?q=goku&page=2`
- 第2页: `https://motionbgs.com/search?q=goku&page=2` → 下一页: `?q=goku&page=3`
- 最后一页: 无 Next 链接

---

## 详情页数据结构

### Meta 标签

| Meta 属性 | 用途 |
|-----------|------|
| `og:title` | 壁纸标题 |
| `og:image` | 海报图 URL |
| `og:video` | 预览视频 URL (可选) |
| `name="description"` | 简介/描述 |

### 下载选项

```html
<a href="/dl/4k/{id}" rel=nofollow target=_blank>
  <span class="font-bold">{label}</span> Wallpaper ({filesize})
</a>
<div class="text-xs">{resolution}</div>
```

**正则表达式：**
```swift
let downloadRegex = #"<a href=([^ >]+) rel=nofollow target=_blank>.*?<span class=font-bold>([^<]+)</span>\s*Wallpaper\s*\(([^)]+)\)</div><div class=text-xs>([^<]+)</div>"#
// 捕获组：
// 1. href (下载 URL)
// 2. label (如 "4K")
// 3. filesize (如 "21.5Mb")
// 4. detailText (如 "3840x2160 mp4 file")
```

### 标签解析

```html
<a href="/tag:{slug}/">
  <span>{tag_name}</span>
</a>
```

**正则表达式：**
```swift
let tagRegex = #"<a href=/tag:([^/]+)/>\s*(?:<picture>.*?</picture>\s*)?(?:<span>)?([^<]+?)(?:</span>)?</a>"#
// 捕获组：
// 1. slug (标签别名)
// 2. tag_name (显示名称)
```

---

## 完整分类系统

### 主要分类 (Categories) - 共15个

| slug | 名称 | URL | 说明 |
|------|------|-----|------|
| `anime` | Anime | `/tag:anime/` | 动漫 |
| `games` | Games | `/tag:games/` | 游戏 |
| `nature` | Nature | `/tag:nature/` | 自然风景 |
| `car` | Car | `/tag:car/` | 汽车 |
| `tv` | TV & Movie | `/tag:tv/` | 影视 |
| `fantasy` | Fantasy | `/tag:fantasy/` | 奇幻 |
| `space` | Space | `/tag:space/` | 太空 |
| `technology` | Technology | `/tag:technology/` | 科技 |
| `holiday` | Holiday | `/tag:holiday/` | 节日 |
| `animal` | Animal | `/tag:animal/` | 动物 |
| `horror` | Horror | `/tag:horror/` | 恐怖 |
| `football` | Football | `/tag:football/` | 足球 |
| `japan` | Japan | `/tag:hello-kitty/` | 日本文化 |
| `superhero` | Superhero | `/tag:superhero/` | 超级英雄 |
| `hello-kitty` | Hello Kitty | `/tag:hello-kitty/` | Hello Kitty |

### Anime 子标签 (完整列表)

| slug | 名称 | slug | 名称 |
|------|------|------|------|
| `girl` | Anime Girl | `one-punch-man` | One Punch Man |
| `demon-slayer` | Demon Slayer | `gundam` | Gundam |
| `naruto` | Naruto | `hatsune-miku` | Hatsune Miku |
| `jujutsu-kaisen` | Jujutsu Kaisen | `sword-art-online` | Sword Art Online |
| `one-piece` | One Piece | `hunter-x-hunter` | Hunter X Hunter |
| `dragon-ball` | Dragon Ball | `death-note` | Death Note |
| `anime-nature` | Anime Nature | `zero-two` | Zero Two |
| `chainsaw-man` | Chainsaw Man | `your-name` | Your Name |
| `fate` | Fate | `black-clover` | Black Clover |
| `bleach` | Bleach | `baki` | Baki |
| `solo-leveling` | Solo Leveling | `rezero` | Re:Zero |
| `attack-on-titan` | Attack on Titan | `dandadan` | Dandadan |
| `blue-lock` | Blue Lock | `mob-psycho` | Mob Psycho |
| `frieren` | Frieren | `ghibli` | Ghibli |
| `my-hero-academia` | My Hero Academia | `mushoku-tensei` | Mushoku Tensei |
| `hololive` | Hololive | `spy-x-family` | Spy X Family |
| `tokyo-ghoul` | Tokyo Ghoul | `spirited-away` | Spirited Away |
| `berserk` | Berserk | `tokyo-revengers` | Tokyo Revengers |
| `princess-connect` | Princess Connect | `haikyuu` | Haikyu |
| `jojos-bizarre-adventure` | Jojo's Bizarre Adventure | `fairy-tail` | Fairy Tail |
| `made-in-abyss` | Made in Abyss | `wind-breaker` | Wind Breaker |

### Games 子标签 (完整列表)

| slug | 名称 | slug | 名称 |
|------|------|------|------|
| `genshin-impact` | Genshin Impact | `gta` | GTA |
| `honkai-star-rail` | Honkai Star Rail | `tower-of-fantasy` | Tower of Fantasy |
| `wuthering-waves` | Wuthering Waves | `dota-2` | Dota 2 |
| `minecraft` | Minecraft | `assassins-creed` | Assassin's Creed |
| `league-of-legends` | League of Legends | `rdr` | RDR |
| `valorant` | Valorant | `roblox` | Roblox |
| `resident-evil` | Resident Evil | `doom` | Doom |
| `elden-ring` | Elden Ring | `wukong` | Wukong |
| `zelda` | Zelda | `warframe` | Warframe |
| `persona` | Persona | `mortal-kombat` | Mortal Kombat |
| `nier-automata` | Nier Automata | `helldivers-2` | Helldivers 2 |
| `overwatch` | Overwatch | `sonic` | Sonic |
| `fortnite` | Fortnite | `skyrim` | Skyrim |
| `apex-legends` | Apex Legends | `brawl-stars` | Brawl Stars |
| `witcher` | Witcher | `sekiro` | Sekiro |
| `azur-lane` | Azur Lane | `pubg` | Pubg |
| `final-fantasy` | Final Fantasy | `the-last-of-us` | The Last of Us |
| `god-of-war` | God of War | `sea-of-thieves` | Sea of Thieves |
| `fallout` | Fallout | `csgo` | CSGO |
| `cyberpunk-2077` | Cyberpunk 2077 | `hunt-showdown` | Hunt Showdown |
| `honkai` | Honkai Impact | `ghost-of-tsushima` | Ghost of Tsushima |
| `punishing-gray-raven` | Punishing: Gray Raven | `fnaf` | FNAF |
| `arknights` | Arknights | `warhammer` | Warhammer 40k |
| `pokemon` | Pokemon | `warcraft` | Warcraft |
| `zennett-zero` | Zenless Zone Zero | `marvel-rivals` | Marvel Rivals |
| `goddess-of-victory-nikke` | Goddess of Victory Nikke | `titanfall` | Titanfall |
| `touhou` | Touhou | `hollow-knight` | Hollow Knight |
| `blue-archive` | Blue Archive | `call-of-duty` | Call of Duty |
| `need-for-speed` | Need for Speed | `mitsubishi` | Mitsubishi |

### Car 子标签

| slug | 名称 | slug | 名称 |
|------|------|------|------|
| `sports-cars` | Sports Cars | `mustang` | Mustang |
| `bmw` | BMW | `ferrari` | Ferrari |
| `nissan` | Nissan | `dodge` | Dodge |
| `jdm` | JDM | `ford` | Ford |
| `audi` | Audi | `honda` | Honda |
| `porsche` | Porsche | `lamborghini` | Lamborghini |
| `bike` | Bike | `mclaren` | McLaren |
| `mercedes` | Mercedes | `mazda` | Mazda |
| `toyota` | Toyota | `subaru` | Subaru |

---

## 热门搜索建议标签

网站侧边栏提供的热门搜索词：

```
anime, demon slayer, car, goku, naruto, bmw, one piece, nature, pokemon,
minecraft, samurai, rain, spiderman, white, batman, space, red, dark,
bleach, cyberpunk, valorant, cat, blue, purple
```

---

## 缩略图 URL 格式

```
https://motionbgs.com/i/c/546x308/media/{id}/{filename}.{ext}.webp
```

---

## 完整数据流

### 首页/分类列表数据流

```
1. 获取首页列表（第1页）
   fetchPage(source: .home)
   └─> GET https://motionbgs.com/hx2/latest/1/

2. 获取分页
   fetchPage(source: .home, pagePath: "2/")
   └─> GET https://motionbgs.com/hx2/latest/2/

3. 解析列表页
   parseListPage(html)
   ├─> 检测 URL 格式判断使用哪个正则
   │   ├─> 包含 "/hx2/latest/" -> 使用 listItemRegexNew
   │   └─> 其他情况 -> 使用 listItemRegexOld
   ├─> listItemRegex 匹配卡片
   │   └─> 提取: slug, title, thumbnailURL, resolutionLabel
   ├─> 从 URL 提取 currentPage 和 nextPagePath
   └─> 返回 MediaListPage
```

### 标签页数据流

```
1. 获取标签列表（第1页）
   fetchPage(source: .tag(slug: "goku"))
   └─> GET https://motionbgs.com/tag:goku/

2. 获取分页
   fetchPage(source: .tag(slug: "goku"), pagePath: "2/")
   └─> GET https://motionbgs.com/tag:goku/2/

3. 解析列表页
   parseListPage(html)
   ├─> 检测 URL 格式: `/tag:([^/]+)/(\d+)/`
   ├─> listItemRegexOld 匹配卡片
   │   └─> 提取: slug, title, thumbnailURL, resolutionLabel
   ├─> 从分页控件提取 nextPagePath
   └─> 返回 MediaListPage
```

### 搜索结果数据流

```
1. 执行搜索（第1页）
   fetchPage(source: .search(query: "goku"))
   └─> GET https://motionbgs.com/search?q=goku

2. 获取分页
   fetchPage(source: .search(query: "goku"), pagePath: "&page=2")
   └─> GET https://motionbgs.com/search?q=goku&page=2

3. 解析搜索结果页
   parseSearchPage(html)
   ├─> listItemRegexOld 匹配卡片
   │   └─> 提取: slug, title, thumbnailURL, resolutionLabel
   ├─> 从 URL 或分页控件提取 nextPagePath
   └─> 返回 MediaListPage
```

### 详情页数据流

```
4. 获取详情页
   fetchDetail(slug: "wuthering-waves-arcane-clash")
   └─> GET https://motionbgs.com/wuthering-waves-arcane-clash

5. 解析详情页
   parseDetailPage(html, slug, pageURL)
   ├─> parseMetaContent("og:title") -> title
   ├─> parseMetaContent("og:image") -> posterURL
   ├─> parseTags() -> [tags]
   ├─> parseDownloadOptions() -> [downloadOptions]
   └─> 返回 MediaItem
```

---

## 缓存策略

```swift
// 列表页缓存（按 URL 缓存）
private var listCache: [String: MediaListPage] = [:]

// 详情页缓存（按 slug 缓存）
private var detailCache: [String: MediaItem] = [:]
```

---

## 关键代码文件

| 文件 | 职责 |
|------|------|
| `Services/MediaService.swift` | 主要数据获取和解析逻辑 |
| `Models/MediaItem.swift` | MediaItem 模型定义 |
| `ViewModels/MediaExploreViewModel.swift` | 媒体浏览页 ViewModel |

---

## 待完善功能

1. **搜索功能对接**：搜索使用 `/search?q={query}` URL，分页用 `&page={n}`
2. **相关推荐**：详情页侧边栏推荐
3. **视频预览**：`og:video` 预览视频 URL
4. **GIF/Mobile 列表**：单独对接

---

## MediaRouteSource 枚举

```swift
enum MediaRouteSource {
    case home           // 首页 (hx2/latest)
    case mobile         // 移动端 (mobile)
    case fourK          // 4K 壁纸 (4k)
    case gifs           // GIF 壁纸 (gifs)
    case tag(slug: String)       // 标签页 (tag:{slug})
    case search(query: String)    // 搜索 (search?q={query})
}
```

### 各 Source 对应的 URL 构建

| Source | 第1页 URL | 分页 URL |
|--------|-----------|----------|
| `.home` | `/hx2/latest/1/` | `/{nextPage}/` |
| `.mobile` | `/mobile/` | `/{nextPage}/` |
| `.fourK` | `/4k/` | `/{nextPage}/` |
| `.gifs` | `/gifs/` | `/{nextPage}/` |
| `.tag(slug)` | `/tag:{slug}/` | `/tag:{slug}/{nextPage}/` |
| `.search(query)` | `/search?q={query}` | `/search?q={query}&page={n}` |

---

## MediaListPage 结构

```swift
struct MediaListPage {
    let items: [MediaItem]        // 壁纸列表
    let nextPagePath: String?      // 下一页路径（如 "2/"）
    let sectionTitle: String       // 区块标题
    let currentPage: Int           // 当前页码
    let hasMorePages: Bool         // 是否有更多页
}
```

---

## MediaItem 结构

```swift
struct MediaItem {
    let slug: String                    // 唯一标识符
    let title: String                  // 标题
    let pageURL: URL                   // 详情页 URL
    let thumbnailURL: URL              // 缩略图 URL
    let resolutionLabel: String?       // 分辨率标签（如 "4K"）
    let collectionTitle: String?      // 所属分类
    let summary: String?               // 简介
    let previewVideoURL: URL?         // 预览视频 URL
    let posterURL: URL?               // 海报图 URL
    let tags: [String]                // 标签数组
    let exactResolution: String?       // 精确分辨率
    let durationSeconds: Double?        // 时长（秒）
    let downloadOptions: [MediaDownloadOption]  // 下载选项
}
```

---

## MediaDownloadOption 结构

```swift
struct MediaDownloadOption {
    let label: String           // 标签（如 "4K", "HD"）
    let fileSizeLabel: String   // 文件大小（如 "21.5Mb"）
    let detailText: String       // 详情（如 "3840x2160 mp4 file"）
    let remoteURL: URL           // 下载 URL
}
```

---

*文档生成时间: 2026-03-26*
*数据来源: https://motionbgs.com*
