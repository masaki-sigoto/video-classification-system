# CLAUDE.md — ScreenVault

## プロジェクト概要

**ScreenVault** は macOS ネイティブアプリ（Swift + SwiftUI）で、スクリーンショット・画面録画・クリップボード画像・動画・テキストを自動でクラウドドライブ（Google Drive / OneDrive / Dropbox / iCloud Drive）へ保存・分類するシステム。

- 要件定義書: `Macスクリーンショット等の自動クラウド保存・分類システム 要件定義.md`
- 対象OS: macOS Tahoe 26.x / Sequoia 15.x / Sonoma 14.x
- 配布: App Store + 社内配布（Developer ID + Notarization）

## 技術スタック

- **言語**: Swift 6+
- **UI**: SwiftUI（macOS）
- **フレームワーク**: ScreenCaptureKit, Vision, Core ML, CryptoKit, URLSession, OSLog, UserNotifications
- **データ**: SwiftData（ローカルDB）
- **認証**: OAuth 2.0 + PKCE（Google/Microsoft/Dropbox）, Apple ID（iCloud）
- **セキュリティ**: Keychain Services, App Sandbox
- **ビルド**: Xcode 26+ / xcodegen

## ワークフロールール

### コミット規則
- **作業ごとに細かく分割してcommitすること**
- コミットメッセージは日本語でも英語でもよいが、変更内容を明確に記述する
- Conventional Commits 形式を推奨: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`

### Push前レビュー
- **push前にはCodexによるレビューと、それに対する修正を行うこと**
- `codex` CLI でレビューを実施し、指摘事項を修正してからpush
- レビュー観点: セキュリティ（トークン漏洩、権限過剰）、パフォーマンス、コード品質

### 作業の委任
- **基本的には作業はサブエージェントに委任することでコンテキストを削減し、PMのように振る舞うこと**
- 実装タスクは `Task` ツール（subagent）に委任する
- メインエージェントはタスク管理・レビュー・統合に集中する
- サブエージェントには必要な文脈（ファイルパス、要件、既存コードの参照先）を明確に伝える

## コーディング規約

- Swift API Design Guidelines に準拠
- `async/await` + Structured Concurrency を優先（Combine は必要な場合のみ）
- エラーは型付きエラー（`enum XXXError: Error`）で定義
- ログは `OSLog` + `Logger` を使用（`print` 禁止）
- 秘密情報は Keychain に保存（UserDefaults 禁止）
- ファイルアクセスは Security-Scoped Bookmark を使用

## ディレクトリ構成

```
ScreenVault/
├── App/                    # アプリエントリポイント、App struct
├── Features/               # 機能別モジュール
│   ├── Ingest/            # 取り込み（Watch/Capture/Clipboard）
│   ├── Classification/    # 自動分類（メタデータ/OCR/ML）
│   ├── Upload/            # アップロードキュー・再開可能アップロード
│   ├── Providers/         # クラウドプロバイダコネクタ
│   │   ├── GoogleDrive/
│   │   ├── OneDrive/
│   │   ├── Dropbox/
│   │   └── iCloud/
│   ├── Settings/          # 設定画面
│   └── Sharing/           # 共有設定
├── Core/                   # 共通基盤
│   ├── Models/            # データモデル（Asset, UploadTask 等）
│   ├── Database/          # SwiftData スキーマ・マイグレーション
│   ├── Security/          # Keychain, OAuth
│   ├── Logging/           # OSLog ラッパー
│   └── Extensions/        # Swift 拡張
├── Resources/              # アセット、ローカライゼーション
└── Tests/                  # ユニットテスト・統合テスト
```

## 重要な設計判断

1. **Watchモード + Captureモードの二系統**: 要件定義書に基づく
2. **Provider Connector パターン**: クラウドごとの差異を抽象化
3. **再開可能アップロード必須**: 大容量動画対応（Google/OneDrive/Dropbox それぞれの仕様に準拠）
4. **分類パイプライン**: Stage 0→4 の段階的分類（メタデータ→ルール→OCR→ML）
5. **App Sandbox 準拠**: Security-Scoped Bookmark でフォルダアクセス永続化
