# WaifuX

<p align="center">
  <a href="README.md">🇨🇳 简体中文</a> | <a href="README.en.md">🇺🇸 English</a> | <a href="README.ja.md">🇯🇵 日本語</a>
</p>

<p align="center">
  <img src="Design/Logo/AppIcon_Glass.png" width="120" height="120" />
</p>

<p align="center">
  <samp>
    <b>macOS 开源 ACG 一站式应用</b><br>
    <b>静态壁纸 · 动态壁纸 · 动漫视频</b><br>
    <b>多源聚合，全场景覆盖</b>
  </samp>
</p>

<p align="center">
  <a href="https://github.com/jipika/WaifuX/releases">
    <img src="https://img.shields.io/github/v/release/jipika/WaifuX?color=6366f1&style=flat-square" alt="Release">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-GPL--3.0-06b6d4?style=flat-square" alt="License">
  </a>
  <a href="https://github.com/jipika/WaifuX/stargazers">
    <img src="https://img.shields.io/github/stars/jipika/WaifuX?color=f59e0b&style=flat-square" alt="Stars">
  </a>
  <a href="https://github.com/jipika/WaifuX/forks">
    <img src="https://img.shields.io/github/forks/jipika/WaifuX?color=10b981&style=flat-square" alt="Forks">
  </a>
  <a href="https://github.com/jipika/WaifuX/releases">
    <img src="https://img.shields.io/github/downloads/jipika/WaifuX/total?color=8b5cf6&style=flat-square" alt="Downloads">
  </a>
  <a href="https://jipika.github.io/WaifuX">
    <img src="https://img.shields.io/badge/Website-🌐-ec4899?style=flat-square" alt="Website">
  </a>
</p>

---

## 📸 界面预览

<table width="100%">
  <tr>
    <td width="50%"><img src="screenshots/home.png" width="100%" /><br><p align="center">首页 - 精选推荐</p></td>
    <td width="50%"><img src="screenshots/wallpaper.png" width="100%" /><br><p align="center">壁纸浏览 - 智能筛选</p></td>
  </tr>
  <tr>
    <td width="50%"><img src="screenshots/wallpaper_detail.png" width="100%" /><br><p align="center">壁纸详情 - 一键设置</p></td>
    <td width="50%"><img src="screenshots/settings.png" width="100%" /><br><p align="center">设置 - 个性化配置</p></td>
  </tr>
  <tr>
    <td width="50%"><img src="screenshots/motionbg.png" width="100%" /><br><p align="center">动态壁纸 - MotionBG</p></td>
    <td width="50%"><img src="screenshots/anime_detail.png" width="100%" /><br><p align="center">动漫详情 - 多源解析</p></td>
  </tr>
  <tr>
    <td width="50%"><img src="screenshots/anime_video.png" width="100%" /><br><p align="center">视频播放 - 选集管理</p></td>
    <td width="50%"><img src="screenshots/paging_mode.png" width="100%" /><br><p align="center">我的库 - 设置</p></td>
  </tr>
</table>

---

## ✨ 功能一览

| 功能 | 状态 | 说明 |
|------|:----:|------|
| 🖼 **静态壁纸** | ✅ | 双源切换：Wallhaven + 4K Wall，4K/8K 全分辨率覆盖 |
| 🎬 **动态壁纸** | ✅ | 支持 MotionBGs 等动态背景源，让桌面"活"起来 |
| 📺 **动漫视频** | ✅ | 内置多源解析引擎，追番观影一站式完成 |
| 🔍 **智能搜索与筛选** | ✅ | 关键词、标签、分类、颜色、分辨率等多维度筛选 |
| ⭐ **收藏系统** | ✅ | 收藏喜欢的壁纸、视频，建立个人 ACG 资源库 |
| ⚡️ **一键设为桌面** | ✅ | 浏览中即可快速设置为桌面壁纸或动态桌面 |
| 🖥️ **多显示器支持** | ✅ | 支持为每个显示器分别设置不同壁纸，多屏用户福音 |
| 📥 **本地数据导入** | ✅ | 支持导入本地壁纸文件夹，统一管理个人壁纸收藏 |
| 🧊 **Wallpaper Engine 渲染 (Beta)** | ✅ | 实验性兼容 Wallpaper Engine 动态壁纸：**场景（Scene）** 与 **Web**（HTML/JS）类型均由内置渲染管线呈现；**不是**「任意网站一键当壁纸」<br>⚠️ **仅支持 Apple Silicon（arm64），Intel 芯片暂不支持** |
| 🔄 **规则自动更新** | ✅ | 通过 GitHub 远程加载规则配置，源站改版可快速适配 |
| 📱 **跨设备同步** | 🚧 | 收藏夹云端同步（开发中）|

---

## 📥 安装

### 方式一：官网下载（推荐）

👉 **[https://jipika.github.io/WaifuX](https://jipika.github.io/WaifuX)**

### 方式二：GitHub Releases

👉 **[Releases](https://github.com/jipika/WaifuX/releases)**

### 方式三：Homebrew

```bash
brew tap jipika/waifux
brew install --cask waifux
```

### 方式四：夸克网盘

👉 **[https://pan.quark.cn/s/aa3ed02db5cf](https://pan.quark.cn/s/aa3ed02db5cf)**

> ⚠️ 首次打开可能需要在「系统设置 → 隐私与安全性」中允许运行。

---

## 🌐 网络要求

> ⚠️ **中国大陆用户请注意**

WaifuX 的主要数据源 [Wallhaven](https://wallhaven.cc) 托管在海外服务器，**在中国大陆地区直接访问可能存在网络问题**。如遇到无法加载内容的情况，请确保网络环境可以正常访问境外网站。

---

## 🛠 系统要求

- **macOS 14.0+**（Sonoma 及以上版本）
- 支持 **Apple Silicon（M 系列）** 和 **Intel** 芯片的 Mac

---

## 🔧 规则引擎

WaifuX 采用动态规则机制，爬取逻辑与客户端分离：

- 规则托管于独立仓库：**[WaifuX-Profiles](https://github.com/jipika/WaifuX-Profiles)**
- 应用启动时自动同步最新规则
- 支持用户自定义导入规则
- 源站页面结构调整时，仅需更新规则即可适配，无需发版

```
应用启动 → 检查规则更新 → 加载最新规则 → 正常使用
                ↑________________________|
                   （远程仓库更新后自动同步）
```

---

## 🌍 多语言支持

| 语言 | 状态 |
|------|:----:|
| 🇨🇳 简体中文 | ✅ 完整支持 |
| 🇺🇸 English | ✅ Full Support |
| 🇯🇵 日本語 | ✅ 完全対応 |

---

## ☕ 支持开源

WaifuX 是一个**完全免费、开源**的个人项目。开发和维护一个 macOS 原生应用需要投入大量时间和精力——从界面设计到功能实现，从 Bug 修复到规则适配，每一个版本背后都是业余时间的持续投入。

如果你觉得 WaifuX 对你有帮助，欢迎通过以下方式支持项目的持续发展：

### 💬 加入 QQ 群

- **WaifuX 用户交流群**: [点击加入](https://qm.qq.com/q/SRCj8msygq) 👈 971414910

<p align="center">
  <img src="reward.jpg" width="280" alt="微信赞赏码" />
  <img src="afdian_reward.jpg" width="280" alt="爱发电赞助码" />
</p>

当然，**给项目点个 Star ⭐️** 同样是对开发者最大的鼓励！

每一份支持都是我继续维护和迭代这款应用的动力。感谢使用 WaifuX 💜

---

## 📄 开源协议

本项目基于 [GNU General Public License v3.0 (GPL-3.0)](LICENSE) 开源。

---

## ⚠️ 免责声明

### 1. 内容聚合声明
WaifuX 本身**不存储、不托管任何内容**，仅作为第三方内容的聚合与展示工具：
- [Wallhaven](https://wallhaven.cc) 壁纸通过其公开 API 获取
- [MotionBGs](https://motionbgs.com) 内容由用户自行配置源地址
- 动漫视频解析源由用户自行提供与配置
- 所有内容的版权归原网站及原作者所有

### 2. Wallpaper Engine 兼容性声明（实验性 / Beta）
WaifuX **并非 Wallpaper Engine 官方产品**，与 Valve Corporation、Kristjan Skutta / Wallpaper Engine 及其关联方**不存在任何官方合作、赞助或隶属关系**。应用内集成的 Wallpaper Engine 场景渲染功能属于**实验性第三方兼容实现**，基于用户自行拥有的 Workshop 内容或本地文件进行 OpenGL 渲染，仅供个人学习、研究与 interoperability（互操作性）目的使用。
- 用户**必须自行合法拥有** Wallpaper Engine 软件许可及相关 Workshop 内容的合法使用权
- 本应用不会、也无法验证用户是否拥有相应内容的合法授权
- 若用户未购买 Wallpaper Engine 或未获得内容授权，请**不要**使用本功能
- 因使用本功能产生的任何版权、许可或服务条款争议，**由用户自行承担全部法律责任**
- **本软件本身不包含任何 Wallpaper Engine 的版权数据、Workshop 内容、着色器、模型或纹理。** 所有渲染所需的素材均来源于用户自行提供的本地文件或 Workshop 订阅，本应用仅在运行时读取并渲染这些用户已有的数据

### 3. 第三方软件与素材声明
- 本应用包含对第三方专有格式（如 PKG）的结构解析，仅用于在 macOS 平台上实现互操作性
- 用户通过本应用加载、播放或展示的任何第三方素材（包括但不限于壁纸、视频、音频、模型、Shader），其合法性、版权归属及使用授权均由用户自行负责
- 开发者不对用户上传、导入或访问的任何第三方内容的合法性做任何担保

### 4. 使用限制
- 请严格遵守各内容平台的服务条款与最终用户许可协议（EULA）
- 禁止将本应用用于任何侵犯知识产权、传播非法内容或违反适用法律法规的行为
- 本应用仅供个人学习研究使用，**禁止商业性再分发或用于非法营利**

### 5. 责任限制
本应用按「**原样（AS IS）**」提供，开发者不对以下情形承担任何责任：
- 因网络波动、第三方服务变更、源站屏蔽等原因导致的内容无法加载
- 因用户设备配置、系统更新、驱动兼容性（特别是 OpenGL / GPU 驱动）导致的渲染异常、崩溃或硬件损坏
- 因用户违反当地法律法规或第三方服务条款而产生的任何法律纠纷、行政处罚或经济损失
- 因用户误操作、数据丢失或其他不可抗力导致的任何直接或间接损失

**使用本应用即表示您已充分理解并同意上述全部条款。如您不同意，请立即停止使用并卸载本应用。**

---

## 🌟 Star 历史

<p align="center">
  <img src="https://api.star-history.com/svg?repos=jipika/WaifuX&type=Date" alt="Star History Chart">
</p>

---

<p align="center">
  <samp>
    Made with 💜 by <a href="https://github.com/jipika">@jipika</a>
  </samp>
</p>

<p align="center">
  <a href="https://github.com/jipika/WaifuX/stargazers">
    <img src="https://img.shields.io/github/stars/jipika/WaifuX?style=social" alt="Stars">
  </a>
</p>
