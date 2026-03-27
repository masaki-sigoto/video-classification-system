# ScreenVault Task Worker Memory

## プロジェクト概要
- macOS SwiftUI アプリ (Swift 6, SwiftData, OSLog)
- プロジェクトルート: /Users/apple/Desktop/アプリ開発（プライベート）/録画分類システム 要件定義

## 重要ファイルパス
- Plans.md: タスク管理
- ScreenVault/Core/Logging/SVLogger.swift: ログカテゴリ定義
- ScreenVault/Core/Security/KeychainHelper.swift: Keychain CRUD
- ScreenVault/Core/Security/OAuthManager.swift: OAuth 2.0 + PKCE 共通基盤
- ScreenVault/Features/Providers/ProviderConnector.swift: プロトコル定義
- ScreenVault/Features/Providers/ProviderManager.swift: アカウント管理 + コネクタファクトリ
- ScreenVault/Features/Ingest/FolderWatcher.swift: FSEvents フォルダ監視
- ScreenVault/Features/Ingest/IngestPipeline.swift: Asset 生成パイプライン

## 実装パターン
- エラー型: ScreenVaultError (OAuthManager.swift に定義済み)
- ログ: SVLogger.ingest / .auth / .provider / .upload / .classification / .general
- 非同期: async/await + AsyncStream でファイル通知
- FolderWatcher: FSEventStreamCreate + kFSEventStreamCreateFlagFileEvents を使用
  - passUnretained を使う（passRetained は deinit でリリースが必要で複雑になるため）
  - stopWatching では queue.async でキャンセルを投入（queue.sync はデッドロックのリスクがあるため）
- OAuthManager: @MainActor on startOAuthFlow / refreshAccessToken (ASWebAuthenticationSession はメインスレッド要件)
- IngestPipeline: SHA-256 は Task.detached(priority: .utility) でメインスレッドをブロックしない

## Phase 1.10 実装済みUI (2026-03-09)
- ScreenVault/App/ScreenVaultApp.swift: AppDelegate, SyncState enum, SyncViewModel(@Observable/@MainActor), @main App
- ScreenVault/App/ContentView.swift: メニューバーウィンドウ 280pt
- ScreenVault/Features/Settings/{SettingsView,GeneralSettingsView,ProvidersSettingsView,ClassificationSettingsView,LogViewerView,FailedTasksView}.swift

### SwiftUI パターン
- @Observable ViewModel は App で `@State private var vm = VM()` として保持
- 子 View への伝播: `.environment(syncVM)` → 子で `@Environment(SyncViewModel.self)`
- #Predicate での enum 比較: `$0.status == EnumType.caseName` 形式が安全
- MenuBarExtra label のアイコンを syncVM.syncState.systemImage で動的変更
- ProviderType に displayName/systemImageName/iconColor を extension で追加

## プロバイダコネクタ (Phase 1.4〜1.6) 実装パターン

### 共有ファイル
- `ScreenVault/Features/Providers/OAuthWebAuthHelper.swift`: OAuth ブラウザ認証共通（OAuthWebAuth.authenticate / OAuthPresentationContextProvider）
- `ScreenVault/Features/Providers/RemoteFolderCacheStore.swift`: フォルダ ID インメモリキャッシュ（全プロバイダ共通）

### OAuth / PKCE
- PKCE SHA-256 は `CryptoKit` の `SHA256.hash(data:)` を使う（CommonCrypto は不要）
- `import CommonCrypto` を関数内に書くことは Swift では不可（トップレベルのみ）
- ASWebAuthenticationSession は `OAuthWebAuth.authenticate(url:callbackScheme:)` に共通化

### コネクタ固有設定
- Google Drive: `GD_CLIENT_ID` (Info.plist)、drive.file スコープ、md5Checksum
- OneDrive: `OD_CLIENT_ID` (Info.plist)、approot 特殊フォルダ、quickXorHash
  - チャンク PUT は Authorization ヘッダー不要（uploadUrl への直接 PUT）
- Dropbox: `DBX_APP_KEY` (Info.plist)、150MB 境界で直接/セッションアップロード切替、content_hash
  - 共有リンク作成 409 は "already exists" → 成功扱い

### エラーハンドリング
- 401 → トークンリフレッシュ後リトライ
- 429 → Retry-After 尊重（デフォルト 60秒）
- 5xx → 指数バックオフ（最大 60秒）

### Keychain キー命名規則
- `{gd|od|dbx}_access_{accountID}`, `_refresh_`, `_expiry_`

### 注意点
- print 禁止、OSLog (SVLogger) を必ず使う
- アクセストークン等は privacy: .private でログに残さない
- SwiftData ModelContext は MainActor 上で操作する
- Bash ツールは現在使用不可（権限なし）
- `Data(contentsOf:)` は大ファイル時にメモリ圧迫 → `URLSession.upload(for:fromFile:)` を優先
- `Data+base64URLEncoded()` を各ファイルで `private extension` として定義（衝突なし）

## Phase 3 テスト・配布・運用基盤 実装パターン (2026-03-09)

### Swift Testing フレームワーク
- `@Suite` + `@Test` + `#expect` を使用（XCTest は使わない）
- `@MainActor` が必要なテストは `@Suite` 全体に付与するのがシンプル（各メソッドへの個別付与も可）
- インメモリ SwiftData: `DatabaseContainer.makeInMemoryContainer()` で取得
- `@Model` クラスは ModelContext なしでも直接インスタンス化可（テスト用途）

### ClassificationEngine + PathResolver 配置
- ClassificationEngine.swift の末尾に PathResolver を同居させた（ファイル数を増やさず）
- `ClassificationEngine.folderName(for:)` は static func として公開（PathResolver から呼ぶため）
- PathResolver のテンプレート展開は長いキーを先に置換（`{YYYY-MM}` の前に `{YYYY}` が展開される問題を回避）

### DuplicateDetector 配置
- NetworkMonitor.swift の末尾に同居させた（Upload 機能ファイルとして自然な場所）
- `@MainActor` + `ModelContext` を使う検索処理

### LogExporter
- `NSSavePanel` は `@MainActor` 必須（runModal() のため）
- CSV エクスポートは RFC 4180 準拠（カンマ・ダブルクォート・改行を含む場合は囲む）
- `import UniformTypeIdentifiers` が UTType 参照に必要

### MetricsCollector
- `ObservableObject` + `@Published` は `import Combine` が必要（`import Observation` ではない）
- `@MainActor final class` で ModelContext を直接使う設計

### Write ツールの制約
- 新規ファイル作成も「Read してから」が必要（存在しないファイルの Read はエラーを返すが記録される）
- 既存ファイルへの追記は Edit ツールが有効

## Phase 2.1〜2.4 + 2.6 実装パターン (2026-03-09)

### ScreenCapture (ScreenCaptureKit)
- `SCScreenshotManager.captureImage(contentFilter:configuration:)` は macOS 14.0+
- 全画面: `SCContentFilter(display:excludingWindows:[])`, 単一ウィンドウ: `SCContentFilter(desktopIndependentWindow:)`
- `SCContentFilter(display:including:[SCWindow])` は存在しない
- 録画: `SCStream` + `AVAssetWriter` (`SCStreamOutput` プロトコル実装)
- `SCStreamConfiguration.width/height` は `Int` 型

### HotkeyManager + ClipboardWatcher
- `@MainActor final class` の `deinit` ではアクター隔離プロパティ不可 → deinit に removeMonitor/invalidate を書かない
- `Timer` は `RunLoop.current.add(timer, forMode: .common)` でバックグラウンド動作を維持
- `lazy var contentStream: AsyncStream` + `continuation` パターンで AsyncStream を公開

### OCRClassifier + ImageClassifier
- `VNRecognizeTextRequest`: `recognitionLanguages = ["ja-JP", "en-US"]`, `.accurate`, `usesLanguageCorrection = true`
- `VNClassifyImageRequest` はモデル不要 (Apple 組み込み)、`VNCoreMLRequest` はカスタム差し込み口
- `withCheckedThrowingContinuation` で Vision コールバックを async/await 化

### SetupWizardView
- `@AppStorage("hasCompletedSetup")` で初回判定
- `WizardStep: Int, CaseIterable, Comparable` でステップ定義
- `NSOpenPanel.runModal()` はメインスレッド必須
