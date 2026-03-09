# ScreenVault

macOS 上のスクリーンショット・録画・クリップボード画像を自動でクラウドに分類・保存するアプリです。

## 概要

ScreenVault は、macOS のスクリーンショット保存フォルダを監視し、新規ファイルを検出すると自動的に分類・命名してクラウドストレージにアップロードします。複数の分類ステージ（種別判定 → ファイル名パース → ユーザールール）で整理されたフォルダ構成を実現します。

## 主な機能

- フォルダ監視（FSEvents） — 指定フォルダへの新規ファイル追加を検知して自動取り込み
- 3 ステージ自動分類 — AssetKind / macOS 標準命名規則 / ユーザー定義ルール
- SHA-256 重複検出 — 同一ファイルの二重アップロードを防止
- クラウドアップロード — Google Drive / OneDrive / Dropbox / iCloud Drive に対応
- OAuth 2.0 + PKCE 認証 — 安全なトークン管理（Keychain 格納）
- 監査ログ — 全操作を AuditLog に記録し CSV / JSON でエクスポート
- メトリクス集計 — 取り込み件数・アップロード成功率をリアルタイム表示
- メニューバー常駐 — 同期状態をメニューバーアイコンで確認

## 前提条件

| 項目 | 要件 |
|------|------|
| macOS | 14.0 (Sonoma) 以上 |
| Xcode | 26 以上 (Swift 6.0) |
| xcodegen | 2.x 以上 |
| Homebrew | 任意（xcodegen のインストールに使用） |

## ビルド手順

1. Xcode ライセンスへの同意（初回のみ）

```bash
sudo xcodebuild -license accept
```

2. xcodegen のインストール（未インストールの場合）

```bash
brew install xcodegen
```

3. Xcode プロジェクトを生成する

```bash
xcodegen generate
```

4. `ScreenVault.xcodeproj` を Xcode で開いてビルドする

```bash
open ScreenVault.xcodeproj
```

Xcode で `Product > Build` (`Cmd+B`) を実行してください。

## ディレクトリ構成

```
ScreenVault/
├── App/
│   ├── ScreenVaultApp.swift      # アプリエントリーポイント
│   └── ContentView.swift         # ルートビュー
├── Core/
│   ├── Models/                   # SwiftData モデル
│   │   ├── Asset.swift
│   │   ├── UploadTask.swift
│   │   ├── ProviderAccount.swift
│   │   ├── OAuthToken.swift
│   │   ├── ClassificationRule.swift
│   │   ├── AuditLog.swift
│   │   ├── AssetTag.swift
│   │   └── RemoteFolderCache.swift
│   ├── Database/
│   │   └── DatabaseContainer.swift
│   ├── Extensions/
│   │   └── HashHelper.swift      # SHA-256 ハッシュ計算
│   ├── Logging/
│   │   ├── SVLogger.swift        # OSLog カテゴリ定義
│   │   ├── LogExporter.swift     # CSV/JSON エクスポート
│   │   └── MetricsCollector.swift
│   ├── Security/
│   │   ├── KeychainHelper.swift  # Keychain CRUD
│   │   ├── BookmarkManager.swift # Security-Scoped Bookmark
│   │   └── OAuthManager.swift    # OAuth 2.0 + PKCE
│   └── ScreenVaultError.swift    # アプリ共通エラー型
├── Features/
│   ├── Classification/
│   │   └── ClassificationEngine.swift  # 分類ロジック + PathResolver
│   ├── Ingest/
│   │   ├── FolderWatcher.swift   # FSEvents フォルダ監視
│   │   └── IngestPipeline.swift  # Asset 生成パイプライン
│   ├── Providers/
│   │   ├── ProviderConnector.swift
│   │   ├── ProviderManager.swift
│   │   ├── GoogleDrive/
│   │   ├── OneDrive/
│   │   └── iCloud/
│   ├── Settings/
│   │   └── SettingsView.swift
│   └── Upload/
│       ├── NetworkMonitor.swift
│       └── DuplicateDetector.swift  (NetworkMonitor.swift 内に定義)
└── Resources/
    ├── Info.plist
    └── ScreenVault.entitlements

ScreenVaultTests/
├── AssetTests.swift
├── ModelTests.swift
├── HashHelperTests.swift
├── ClassificationEngineTests.swift
├── PathResolverTests.swift
├── DuplicateDetectorTests.swift
└── ScreenVaultErrorTests.swift
```

## ライセンス

MIT License

Copyright (c) 2025 ScreenVault Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
