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

## 📸 スクリーンショット

<table width="100%">
  <tr>
    <td width="50%"><img src="screenshots/home.png" width="100%" /><br><p align="center">ホーム - おすすめ</p></td>
    <td width="50%"><img src="screenshots/wallpaper.png" width="100%" /><br><p align="center">壁紙ブラウズ - スマート検索</p></td>
  </tr>
  <tr>
    <td width="50%"><img src="screenshots/wallpaper_detail.png" width="100%" /><br><p align="center">壁紙詳細 - ワンクリック設定</p></td>
    <td width="50%"><img src="screenshots/settings.png" width="100%" /><br><p align="center">設定 - パーソナライズ</p></td>
  </tr>
  <tr>
    <td width="50%"><img src="screenshots/motionbg.png" width="100%" /><br><p align="center">動的壁紙 - MotionBG</p></td>
    <td width="50%"><img src="screenshots/anime_detail.png" width="100%" /><br><p align="center">アニメ詳細 - マルチソース</p></td>
  </tr>
  <tr>
    <td width="50%"><img src="screenshots/anime_video.png" width="100%" /><br><p align="center">ビデオ再生 - エピソード選択</p></td>
    <td width="50%"><img src="screenshots/paging_mode.png" width="100%" /><br><p align="center">マイライブラリ - 設定</p></td>
  </tr>
</table>

---

## ✨ 機能一覧

| 機能 | 状態 | 説明 |
|------|:----:|------|
| 🖼 **静的壁紙** | ✅ | デュアルソース切替：Wallhaven + 4K Wall、4K/8K フル解像度カバー |
| 🎬 **ダイナミック壁紙** | ✅ | MotionBGs などの動的背景ソース対応、デスクトップを"生きている"状態に |
| 📺 **アニメ動画** | ✅ | ビルトインマルチソース解析エンジンでストリーミング・視聴 |
| 🔍 **スマート検索＆フィルタ** | ✅ | キーワード、タグ、カテゴリ、色、解像度 — 目的のコンテンツを素早く発見 |
| ⭐ **コレクション** | ✅ | 気に入った壁紙や動画を保存して個人 ACG ライブラリーを構築 |
| ⚡️ **ワンクリック適用** | ✅ | 閲覧中にそのままデスクトップ壁紙やダイナミック壁紙に設定可能 |
| 🖥️ **マルチディスプレイ対応** | ✅ | 各ディスプレイに異なる壁紙を設定可能 — マルチモニターユーザーに最適 |
| 📥 **ローカルデータインポート** | ✅ | ローカルの壁紙フォルダをインポートして個人コレクションを一元管理 |
| 🧊 **Wallpaper Engine レンダリング (Beta)** | ✅ | Wallpaper Engine 動的壁紙を実験対応：**シーン（Scene）** と **Web**（HTML/JS）タイプを内蔵レンダラーで表示（任意の Web サイトを壁紙にする機能ではありません）<br>⚠️ **Apple Silicon（arm64）のみ対応。Intel チップは現在未対応** |
| 🔄 **自動更新ルール** | ✅ | GitHub 経由でリモート読み込み、ソースサイトの変更にも迅速対応 |
| ☁️ **クロスデバイス同期** | 🚧 | お気に入りのクラウド同期（開発中）|

---

## 📥 インストール

### 方法1：公式ウェブサイト（推奨）

👉 **[https://jipika.github.io/WaifuX](https://jipika.github.io/WaifuX)**

### 方法2：GitHub Releases

👉 **[Releases](https://github.com/jipika/WaifuX/releases)**

### 方法3：Homebrew

```bash
brew tap jipika/waifux
brew install --cask waifux
```

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
  <img src="reward.jpg" width="280" alt="WeChat 報酬QRコード" />
  <img src="afdian_reward.jpg" width="280" alt="Afdian スポンサーQRコード" />
</p>

もちろん、**スター ⭐️ を付けるだけ**でも大きな励みになります！

すべてのサポートが、このアプリを維持・改善し続ける原動力になります。WaifuX をご利用いただきありがとうございます 💜

---

## 📄 ライセンス

本プロジェクトは [GNU General Public License v3.0 (GPL-3.0)](LICENSE) の下でオープンソースとして公開されています。

---

## ⚠️ 免責事項

### 1. コンテンツ集約について
WaifuX 自体は**いかなるコンテンツも保存・ホストしておらず**、純粋に第三者コンテンツの集約・表示ツールとして機能します：
- [Wallhaven](https://wallhaven.cc) の壁紙は公開 API 経由で取得されます
- [MotionBGs](https://motionbgs.com) のコンテンツはユーザー自身がソースアドレスを設定します
- アニメ動画の解析ソースはユーザー自身が提供・設定します
- 全てのコンテンツの著作権は元サイトおよび作者に帰属します

### 2. Wallpaper Engine 互換性に関する声明（実験的 / Beta）
WaifuX は **Wallpaper Engine の公式製品ではありません**。Valve Corporation、Kristjan Skutta / Wallpaper Engine およびその関連会社との間に、**公式な提携、スポンサー関係、または所属関係は一切ありません**。アプリに統合された Wallpaper Engine シーン レンダリング機能は、**実験的な第三者互換実装**であり、ユーザーが既に所有している Workshop コンテンツまたはローカルファイルを使用して OpenGL レンダリングを行うもので、個人的な学習・研究および相互運用性（interoperability）目的でのみ提供されています。
- ユーザーは、Wallpaper Engine の有効なソフトウェアライセンスおよび関連 Workshop コンテンツの合法的な使用権を**自己責任で保有している必要があります**
- 本アプリケーションは、ユーザーがコンテンツの正当なライセンスや権限を保持しているかどうかを確認することはできません
- Wallpaper Engine を購入していない場合、または必要な権利を有していない場合は、**この機能を使用しないでください**
- 本機能の使用により生じる著作権、ライセンス、または利用規約に関する紛争の**全法的責任はユーザーが負うものとします**
- **本ソフトウェア自体には、Wallpaper Engine の著作権データ、Workshop コンテンツ、Shader、モデル、またはテクスチャは一切含まれていません。** レンダリングに必要な全ての素材は、ユーザーが独自に提供するローカルファイルまたは Workshop 購読から取得され、アプリケーションは実行時にこれらのユーザー所有データを読み込み・レンダリングするのみです

### 3. 第三者ソフトウェアおよびアセットについて
- 本アプリケーションは、macOS 上での相互運用性を実現する目的のみで、特定のプロプライエタリ形式（例：PKG）の構造解析を含みます
- ユーザーが本アプリケーションを通じて読み込み、再生、または表示する第三者アセット（壁紙、動画、音声、モデル、Shader などを含むがこれに限られない）の合法性、著作権の帰属、および使用許諾は、すべてユーザー自身の責任となります
- 開発者は、ユーザーがアップロード、インポート、またはアクセスする第三者コンテンツの合法性について、いかなる保証も行いません

### 4. 使用制限
- すべてのコンテンツプラットフォームの利用規約およびエンドユーザー使用許諾契約（EULA）を厳守してください
- 本アプリケーションを、いかなる知的財産権の侵害、違法コンテンツの配信、または適用法令の違反の目的にも使用しないでください
- 本アプリケーションは個人的な学習・研究目的に限り提供されており、**商業的な再配布や違法な営利行為は禁止されています**

### 5. 責任の制限
本アプリケーションは「**現状有姿（AS IS）**」で提供され、開発者は以下の事象について一切の責任を負いません：
- ネットワークの変動、第三者サービスの変更、ソースサイトのブロックなどによりコンテンツが読み込めない場合
- ユーザーのデバイス構成、システムアップデート、ドライバーの互換性（特に OpenGL / GPU ドライバー）に起因するレンダリング異常、クラッシュ、またはハードウェアの損傷
- ユーザーが現地の法令規制または第三者の利用規約に違反したことにより生じる法的紛争、行政処分、または経済的損失
- ユーザーの誤操作、データの紛失、その他の不可抗力による直接的または間接的な損失

**本アプリケーションを使用することで、上記の全条項を十分に読み、理解し、同意したものとみなされます。同意いただけない場合は、直ちに使用を中止し、アンインストールしてください。**

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
