# WallHaven macOS 26 Liquid Glass 设计规范

## 设计哲学

### 角色设定
专长玻璃态/毛玻璃界面的设计师，打造通透、优雅、科技感的产品展示页。

### 视觉设计理念
以「雾面玻璃卡片 + 背景渐变 + 细腻高光」构建层次：
- 卡片：半透明白/灰 + backdrop-blur
- 边框：1px–2px 高光或渐变描边
- 主要文字：高对比
- 次级资讯：半透明浅色

## 配色方案

### 主色调
- **背景色**: `#0D0D0D` (极深黑)
- **卡片背景**: `rgba(20, 20, 25, 0.7)` + blur
- **玻璃高光**: `rgba(255, 255, 255, 0.08)` 边框

### 点缀色
- **主品牌色**: 荧光粉 `#FF3366`
- **次要品牌色**: 紫罗兰 `#8B5CF6`
- **在线状态**: 绿色 `#22C55E`
- **金色**: `#FFD700`

### 文字色
- **主标题**: 纯白 `#FFFFFF`
- **副标题**: 80% 白 `#FFFFFFCC`
- **辅助文字**: 50% 白 `#FFFFFF80`
- **暗淡文字**: 30% 白 `#FFFFFF4D`

## macOS 26 Liquid Glass 特性实现

### 1. 材质系统
```swift
// 基础玻璃卡片
.background(.ultraThinMaterial.opacity(0.4))
.overlay(
    RoundedRectangle(cornerRadius: 16)
        .stroke(.white.opacity(0.08), lineWidth: 1)
)

// 高光玻璃
.background(
    LinearGradient(
        colors: [.white.opacity(0.1), .white.opacity(0.02)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
)
.background(.ultraThinMaterial)
```

### 2. 动态背景
- **浮动光晕效果**: 使用动画让紫色/粉色光晕缓慢移动
- **径向渐变**: 多层次径向渐变营造深度感
- **模糊处理**: 大范围 blur(radius: 60+) 柔化背景

### 3. 交互效果
- **Hover**: 卡片透明度变化 + 轻微放大 (1.02x)
- **选中态**: 荧光粉背景 + 阴影光晕
- **过渡动画**: spring(response: 0.3, dampingFraction: 0.8)

## 布局结构

```
┌─────────────────────────────────────────────────────────┐
│  Sidebar │         Main Content Area                   │
│  (72px)  │  ┌─────────────────────────────────────┐   │
│          │  │  Top Bar (Search + User)             │   │
│  Logo    │  ├─────────────────────────────────────┤   │
│  Icons   │  │                                     │   │
│  Theme   │  │  Hero Banner      │  Top Streamer   │   │
│          │  │  (Featured)       │  (排名列表)      │   │
│          │  │                   │                 │   │
│          │  └───────────────────┴─────────────────┘   │
│          │  │  TRENDING Section                      │   │
│          │  │  [Filters]                             │   │
│          │  ├─────────────────────────────────────┤   │
│          │  │  Wallpaper Grid Cards                 │   │
│          │  └─────────────────────────────────────┘   │
└──────────┴─────────────────────────────────────────────┘
```

## 组件库

### 1. 侧边栏
- 宽度: 72px
- Logo: 渐变玻璃胶囊
- 导航: 选中态荧光粉 + 阴影
- 主题切换: 胶囊容器

### 2. 顶部栏
- 搜索框: 药丸形状玻璃
- 用户头像: 玻璃边框 + 在线绿点
- CTA按钮: 紫罗兰渐变

### 3. 壁纸卡片
- 圆角: 16-20px
- 悬停: 放大 + 阴影加深
- 信息栏: 玻璃态底部栏
- 分辨率标签: 玻璃胶囊

### 4. 详情页
- 左右分栏布局
- 大图预览: 玻璃容器 + 发光边框
- 操作按钮: 渐变主按钮 + 玻璃次按钮
- 设置壁纸选项: 底部弹窗

## 字体层级

| 层级 | 字号 | 字重 | 颜色 | 用途 |
|------|------|------|------|------|
| H1 | 24px | Bold | 100% 白 | 页面标题 |
| H2 | 18px | Bold | 100% 白 | 区块标题 |
| H3 | 16px | Semibold | 100% 白 | 卡片标题 |
| Body | 14px | Regular | 80% 白 | 正文 |
| Caption | 12px | Medium | 50% 白 | 辅助说明 |
| Tiny | 10px | Medium | 50% 白 | 标签 |

## 间距系统

- xs: 4px
- sm: 8px
- md: 12px
- lg: 16px
- xl: 20px
- 2xl: 24px
- 3xl: 32px

## API 对接

### WallHaven API 集成
- **Base URL**: `https://wallhaven.cc/api/v1`
- **搜索**: `/search?q={query}&page={page}&purity={purity}`
- **详情**: `/w/{id}`
- **图片直链**: `https://w.wallhaven.cc/full/{id_prefix}/{id}.{ext}`

### 功能支持
- [x] 搜索壁纸
- [x] 分类筛选 (General/Anime/People/Nature/Tech)
- [x] 纯净度设置 (SFW/Sketchy/NSFW)
- [x] 排序 (Date/Views/Favorites/Toplist)
- [x] 分页加载
- [x] 下载原图
- [x] 设置桌面壁纸
- [x] 收藏功能

## 已移除的直播元素

根据壁纸软件实际需求，已移除：
- ❌ Live 标签
- ❌ Streamer 排名
- ❌ Start Stream 按钮
- ❌ 观看人数
- ❌ 直播状态指示器

保留并改造：
- ✅ Hero Banner (展示精选壁纸)
- ✅ 排名卡片 (展示热门标签/作者)
- ✅ 网格卡片 (壁纸展示)
- ✅ 分类筛选

## 运行方式

```bash
cd /Volumes/mac/CodeLibrary/Claude/WallHaven
open WallHaven.xcodeproj
```

在 Xcode 中按 `⌘+R` 运行 app。
