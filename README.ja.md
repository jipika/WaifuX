# WaifuX

<p align="center">
  <a href="README.md">🇨🇳 简体中文</a> | <a href="README.en.md">🇺🇸 English</a> | <a href="README.ja.md">🇯🇵 日本語</a>
</p>

<p align="center">
  <img src="Design/Logo/AppIcon_Glass.png" width="120" height="120" />
</p>

<p align="center">
  <samp>
    <b>macOS オープンソース ACG 統合アプリ</b><br>
    <b>静的壁紙 · ダイナミック壁紙 · アニメ動画</b><br>
    <b>マルチソース統合、全シナリオ対応</b>
  </samp>
</p>

<p align="center">
  <a href="https://github.com/jipika/WaifuX/releases">
    <img src="https://img.shields.io/github/v/release/jipika/WaifuX?color=6366f1&style=flat-square" alt="Release">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-MIT-06b6d4?style=flat-square" alt="License">
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

## 📸 スクリーンショット

<table>
  <tr>
    <td><img src="screenshots/home.png" width="100%" /><br><p align="center">ホーム - おすすめ</p></td>
    <td><img src="screenshots/wallpaper.png" width="100%" /><br><p align="center">壁紙ブラウズ - スマート検索</p></td>
    <td><img src="screenshots/wallpaper_detail.png" width="100%" /><br><p align="center">壁紙詳細 - ワンクリック設定</p></td>
    <td><img src="screenshots/settings.png" width="100%" /><br><p align="center">設定 - パーソナライズ</p></td>
  </tr>
  <tr>
    <td><img src="screenshots/motionbg.png" width="100%" /><br><p align="center">動的壁紙 - MotionBG</p></td>
    <td><img src="screenshots/anime_detail.png" width="100%" /><br><p align="center">アニメ詳細 - マルチソース</p></td>
    <td><img src="screenshots/anime_video.png" width="100%" /><br><p align="center">ビデオ再生 - エピソード選択</p></td>
    <td></td>
  </tr>
</table>

---

## ✨ 機能一覧

| 機能 | 状態 | 説明 |
|------|:----:|------|
| 🖼 **静的壁紙** | ✅ | Wallhaven などの高品質ソースに対応、4K/8K フル解像度カバー |
| 🎬 **ダイナミック壁紙** | ✅ | MotionBGs などの動的背景ソース対応、デスクトップを"生きている"状態に |
| 📺 **アニメ動画** | ✅ | ビルトインマルチソース解析エンジンでストリーミング・視聴 |
| 🔍 **スマート検索＆フィルタ** | ✅ | キーワード、タグ、カテゴリ、色、解像度 — 目的のコンテンツを素早く発見 |
| ⭐ **コレクション** | ✅ | 気に入った壁紙や動画を保存して個人 ACG ライブラリーを構築 |
| ⚡️ **ワンクリック適用** | ✅ | 閲覧中にそのままデスクトップ壁紙やダイナミック壁紙に設定可能 |
| 🖥️ **マルチディスプレイ対応** | ✅ | 各ディスプレイに異なる壁紙を設定可能 — マルチモニターユーザーに最適 |
| 📥 **ローカルデータインポート** | ✅ | ローカルの壁紙フォルダをインポートして個人コレクションを一元管理 |
| 🔄 **自動更新ルール** | ✅ | GitHub 経由でリモート読み込み、ソースサイトの変更にも迅速対応 |
| ☁️ **クロスデバイス同期** | 🚧 | お気に入りのクラウド同期（開発中）|

---

## 📥 インストール

### 方法1：公式ウェブサイト（推奨）

👉 **[https://jipika.github.io/WaifuX](https://jipika.github.io/WaifuX)**

### 方法2：GitHub Releases

👉 **[Releases](https://github.com/jipika/WaifuX/releases)**

> ⚠️ 初回起動時、「システム設定 → プライバシーとセキュリティ」で実行許可が必要な場合があります。

---

## 🌐 ネットワーク要件

> ⚠️ **中国本土ユーザーへのお知らせ**

WaifuX の主要データソースである [Wallhaven](https://wallhaven.cc) は海外サーバーでホストされています。**中国本土から直接アクセスできない場合があります。** コンテンツが読み込まれない場合は、海外ウェブサイトにアクセスできるネットワーク環境をご確認ください。

---

## 🛠 システム要件

- **macOS 14.0+**（Sonoma 以降）
- **Apple Silicon（Mシリーズ）** および **Intel** Mac 両方に対応

---

## 🔧 ルールエンジン

WaifuX はダイナミックルールシステムを採用しており、スクレイピングロジックとクライアントを分離しています：

- ルールは独立リポジトリで管理：**[WaifuX-Profiles](https://github.com/jipika/WaifuX-Profiles)**
- アプリ起動時に最新ルールを自動同期
- ユーザーによるカスタムルールインポートに対応
- ソースサイトのレイアウト変更時、ルールのみ更新すれば適応可能（アプリ再リリース不要）

```
アプリ起動 → 更新確認 → 最新ルール読み込み → 使用可能
                  ↑________________________|
                    （リモートリポジトリ更新時に自動同期）
```

---

## 🌍 マルチ言語サポート

| 言語 | ステータス |
|------|:----:|
| 🇨🇳 简体中文 | ✅ 完全対応 |
| 🇺🇸 English | ✅ 完全対応 |
| 🇯🇵 日本語 | ✅ 完全対応 |

---

## ☕ オープンソースをサポートする

WaifuX は**完全無料のオープンソース**個人プロジェクトです。ネイティブ macOS アプリケーションの開発と保守には多大な時間と労力がかかります — UI デザイン、機能実装、バグ修正、ルール適配まで、すべてのバージョンは継続的な個人的な取り組みによって作られています。

もし WaifuX がお役に立ったなら、プロジェクトの継続的な発展を支援することをぜひご検討ください：

<p align="center">
  <img src="reward.jpg" width="280" alt="スポンサーQRコード" />
</p>

もちろん、**スター ⭐️ を付けるだけ**でも大きな励みになります！

すべてのサポートが、このアプリを維持・改善し続ける原動力になります。WaifuX をご利用いただきありがとうございます 💜

---

## 📄 ライセンス

本プロジェクトは [MIT License](LICENSE) の下でオープンソースとして公開されており、自由に使用・配布できます。

---

## ⚠️ 免責事項

WaifuX 自体は**コンテンツを一切保存せず**、あくまで集約ツールとして機能します：

- [Wallhaven](https://wallhaven.cc) の壁紙は公開 API 経由で取得されます
- [MotionBGs](https://motionbgs.com) のコンテンツはユーザー自身がソースアドレスを設定します
- アニメ動画ソースはユーザー自身が提供します
- 全てのコンテンツの著作権は元サイトおよび作者に帰属します
- 各プラットフォームの利用規約に従い、個人利用に限ってお使いください

---

## 🌟 Star 履歴

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
