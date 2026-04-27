# WaifuX

<p align="center">
  <a href="README.md">🇨🇳 简体中文</a> | <a href="README.en.md">🇺🇸 English</a> | <a href="README.ja.md">🇯🇵 日本語</a>
</p>

<p align="center">
  <img src="Design/Logo/AppIcon_Glass.png" width="120" height="120" />
</p>

<p align="center">
  <samp>
    <b>Open Source All-in-One ACG App for macOS</b><br>
    <b>Static Wallpapers · Dynamic Wallpapers · Anime Videos</b><br>
    <b>Multi-source Aggregation, Full-scenario Coverage</b>
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

## 📸 Preview

<table width="100%">
  <tr>
    <td width="50%"><img src="screenshots/home.png" width="100%" /><br><p align="center">Home - Featured</p></td>
    <td width="50%"><img src="screenshots/wallpaper.png" width="100%" /><br><p align="center">Wallpapers - Smart Filter</p></td>
  </tr>
  <tr>
    <td width="50%"><img src="screenshots/wallpaper_detail.png" width="100%" /><br><p align="center">Wallpaper Detail - One-click Set</p></td>
    <td width="50%"><img src="screenshots/settings.png" width="100%" /><br><p align="center">Settings - Personalization</p></td>
  </tr>
  <tr>
    <td width="50%"><img src="screenshots/motionbg.png" width="100%" /><br><p align="center">Live Wallpapers - MotionBG</p></td>
    <td width="50%"><img src="screenshots/anime_detail.png" width="100%" /><br><p align="center">Anime Detail - Multi-source</p></td>
  </tr>
  <tr>
    <td width="50%"><img src="screenshots/anime_video.png" width="100%" /><br><p align="center">Video Player - Episode Select</p></td>
    <td width="50%"><img src="screenshots/paging_mode.png" width="100%" /><br><p align="center">My Library - Settings</p></td>
  </tr>
</table>

---

## ✨ Features

| Feature | Status | Description |
|---------|:------:|-------------|
| 🖼 **Static Wallpapers** | ✅ | Dual source switching: Wallhaven + 4K Wall, full 4K/8K resolution coverage |
| 🎬 **Dynamic Wallpapers** | ✅ | Support for MotionBGs and other dynamic background sources — bring your desktop to life |
| 📺 **Anime Videos** | ✅ | Built-in multi-source parsing engine for streaming and watching anime |
| 🔍 **Smart Search & Filter** | ✅ | Keywords, tags, categories, color, resolution — find exactly what you want |
| ⭐ **Collections** | ✅ | Save favorite wallpapers and videos to build your personal ACG library |
| ⚡️ **One-click Apply** | ✅ | Set as desktop wallpaper or dynamic desktop directly while browsing |
| 🖥️ **Multi-display Support** | ✅ | Set different wallpapers for each display — perfect for multi-monitor setups |
| 📥 **Local Data Import** | ✅ | Import local wallpaper folders for unified management of personal collections |
| 🧊 **Wallpaper Engine Rendering (Beta)** | ✅ | Experimental Wallpaper Engine live wallpapers: **scene** (OpenGL) and **Web** (HTML/JS) types, both via the built-in renderer — not a generic “any website as wallpaper” feature<br>⚠️ **Apple Silicon (arm64) only; Intel chips are not supported** |
| 🔄 **Auto-updating Rules** | ✅ | Rule configurations loaded remotely via GitHub — quick adaptation when source sites change |
| ☁️ **Cross-device Sync** | 🚧 | Cloud sync for favorites (in development) |

---

## 📥 Installation

### Method 1: Official Website (Recommended)

👉 **[https://jipika.github.io/WaifuX](https://jipika.github.io/WaifuX)**

### Method 2: GitHub Releases

👉 **[Releases](https://github.com/jipika/WaifuX/releases)**

### Method 3: Homebrew

```bash
brew tap jipika/waifux
brew install --cask waifux
```

> ⚠️ On first launch, you may need to allow execution in "System Settings → Privacy & Security".

---

## 🌐 Network Requirements

> ⚠️ **Note for users in mainland China**

WaifuX's primary data source, [Wallhaven](https://wallhaven.cc), is hosted on overseas servers. **Direct access from mainland China may be affected by network restrictions.** If you experience issues loading content, please ensure your network can access international websites.

---

## 🛠 System Requirements

- **macOS 14.0+** (Sonoma or later)
- Supports both **Apple Silicon (M-series)** and **Intel** Macs

---

## 🔧 Rule Engine

WaifuX uses a dynamic rule system with scraping logic decoupled from the client:

- Rules are hosted in a separate repository: **[WaifuX-Profiles](https://github.com/jipika/WaifuX-Profiles)**
- Latest rules are automatically synced on app startup
- Supports custom user-imported rules
- When source site layouts change, only rules need updating — no app release required

```
App Launch → Check for Updates → Load Latest Rules → Ready to Use
                    ↑________________________|
                     (Auto-sync when remote repo updates)
```

---

## 🌍 Multi-language Support

| Language | Status |
|----------|:------:|
| 🇨🇳 简体中文 | ✅ Full Support |
| 🇺🇸 English | ✅ Full Support |
| 🇯🇵 日本語 | ✅ Full Support |

---

## ☕ Support Open Source

WaifuX is a **completely free and open-source** personal project. Developing and maintaining a native macOS application requires significant time and effort — from UI design and feature implementation to bug fixes and rule adaptations, every version is built on continuous personal dedication.

If you find WaifuX helpful, please consider supporting its continued development:

<p align="center">
  <img src="reward.jpg" width="280" alt="WeChat Reward QR Code" />
  <img src="afdian_reward.jpg" width="280" alt="Afdian Sponsor QR Code" />
</p>

Of course, **giving a Star ⭐️** is also greatly appreciated!

Every bit of support motivates me to keep maintaining and improving this app. Thank you for using WaifuX 💜

---

## 📄 License

This project is open-sourced under the [GNU General Public License v3.0 (GPL-3.0)](LICENSE).

---

## ⚠️ Disclaimer

### 1. Content Aggregation
WaifuX does **not store or host any content** itself — it acts solely as an aggregator and viewer for third-party content:
- [Wallhaven](https://wallhaven.cc) wallpapers are fetched via their public API
- [MotionBGs](https://motionbgs.com) content is configured by users themselves
- Anime video parsing sources are provided and configured by users
- All content copyrights belong to the original websites and authors

### 2. Wallpaper Engine Compatibility (Experimental / Beta)
WaifuX is **NOT an official Wallpaper Engine product** and has **no official partnership, sponsorship, or affiliation** with Valve Corporation, Kristjan Skutta / Wallpaper Engine, or their associated entities. The integrated Wallpaper Engine scene rendering feature is an **experimental third-party compatibility implementation** that performs OpenGL rendering using Workshop content or local files which the user already owns, and is intended solely for personal study, research, and interoperability purposes.
- Users **must legally own** a valid Wallpaper Engine software license and the legal right to use any related Workshop content
- This application does not and cannot verify whether the user holds a legitimate license or authorization for any content
- If you have not purchased Wallpaper Engine or do not hold the necessary rights, **do not use this feature**
- Any copyright, licensing, or terms-of-service disputes arising from the use of this feature are the **sole responsibility of the user**
- **This software does not contain any copyrighted Wallpaper Engine data, Workshop content, shaders, models, or textures.** All rendering materials are sourced from local files or Workshop subscriptions provided by the user. This application only reads and renders such user-owned data at runtime

### 3. Third-Party Software and Assets
- This application contains structural parsers for certain proprietary formats (e.g., PKG) used solely to achieve interoperability on macOS
- The legality, copyright ownership, and usage authorization of any third-party assets (including but not limited to wallpapers, videos, audio, models, and shaders) loaded, played, or displayed through this application are the sole responsibility of the user
- The developer makes no guarantees regarding the legality of any third-party content uploaded, imported, or accessed by users

### 4. Usage Restrictions
- Please strictly comply with the terms of service and end-user license agreements (EULA) of all content platforms
- The use of this application for any intellectual property infringement, illegal content distribution, or violation of applicable laws and regulations is strictly prohibited
- This application is for personal study and research use only; **commercial redistribution or illegal profit-making is prohibited**

### 5. Limitation of Liability
This application is provided **"AS IS"**, and the developer assumes no liability for:
- Content loading failures caused by network fluctuations, third-party service changes, or source-site blocking
- Rendering anomalies, crashes, or hardware damage caused by user device configurations, system updates, or driver compatibility issues (particularly OpenGL / GPU drivers)
- Any legal disputes, administrative penalties, or economic losses arising from the user's violation of local laws, regulations, or third-party terms of service
- Any direct or indirect losses caused by user error, data loss, or other force majeure events

**By using this application, you acknowledge that you have fully read, understood, and agreed to all of the above terms. If you do not agree, please stop using and uninstall this application immediately.**

---

## 🌟 Star History

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
