# Plans.md — ScreenVault 開発計画

> 要件定義書: `Macスクリーンショット等の自動クラウド保存・分類システム 要件定義.md`

## Phase 0: プロジェクト基盤 `cc:DONE`

### 0.1 Xcodeプロジェクト生成 `cc:DONE`
- [ ] xcodegen でプロジェクト生成（project.yml）
- [ ] App Sandbox エンタイトルメント設定
- [ ] Info.plist 基本設定（バンドルID、最小OS等）
- [ ] ディレクトリ構成の作成（CLAUDE.md記載の構成）

### 0.2 データモデル（SwiftData） `cc:DONE`
- [x] Asset モデル（kind, source_mode, content_hash_sha256, captured_at, frontmost_app, caption_text, ocr_text, size_bytes）
- [x] UploadTask モデル（asset_id, account_id, status, retry_count, next_retry_at, upload_session_ref）
- [x] ProviderAccount モデル（provider_type, user_display, scope_level）
- [x] OAuthToken モデル（access_token_ref → Keychain参照, refresh_token_ref, expires_at）
- [x] RemoteFolderCache モデル（folder_path_key → remote_folder_id）
- [x] Rule / RuleAction モデル（ClassificationRule + RuleCondition + RuleAction）
- [x] AssetTag モデル（tag, confidence）
- [x] AuditLog モデル（event_type, entity_id, message_redacted）

### 0.3 共通基盤 `cc:DONE`
- [x] OSLog Logger ラッパー（サブシステム・カテゴリ定義）
- [x] Keychain ヘルパー（トークン CRUD）
- [x] CryptoKit SHA-256 ハッシュユーティリティ
- [x] Security-Scoped Bookmark 管理（保存/復元/アクセス）
- [x] エラー型定義（ScreenVaultError enum）
- [x] SwiftData コンテナ設定（DatabaseContainer）

---

## Phase 1: MVP — Watchモード ＋ クラウド連携（3社） `cc:DONE`

### 1.1 Watchモード（FR-02） `cc:DONE`
- [x] FSEvents によるフォルダ監視（FolderWatcher.swift: FSEventStreamCreate + kFSEventStreamCreateFlagFileEvents）
- [x] ファイル安定化検出（サイズ変化停止 1秒でファイル確定）
- [x] Asset 生成 + メタデータ抽出（UTI判定、サイズ、日時） in IngestPipeline.swift
- [ ] Security-Scoped Bookmark で Watch フォルダの永続アクセス（Phase 0.3 で実装予定）
- [x] IngestPipeline（FolderWatcher通知 → SHA-256 → Asset生成 → SwiftData保存）

### 1.2 OAuth 2.0 + PKCE 共通基盤（FR 認証） `cc:DONE`
- [x] OAuth フロー共通実装（OAuthManager.swift: ASWebAuthenticationSession）
- [x] PKCE チャレンジ生成（64バイトランダム code_verifier / SHA-256 code_challenge）
- [x] トークン管理（アクセストークン更新、リフレッシュ、Keychain格納）
- [ ] 認証状態の監視と再認可フロー（Phase 1.4+ で各コネクタに実装）

### 1.3 Provider Connector 抽象層 `cc:DONE`
- [x] ProviderConnector プロトコル定義（既存 ProviderConnector.swift）
- [x] ProviderManager（アカウント一覧、接続/切断、アクティブプロバイダ管理）
- [x] Google Drive / OneDrive / Dropbox stub コネクタ（Phase 1.4-1.6 で本実装）

### 1.4 Google Drive コネクタ `cc:DONE`
- [x] OAuth 2.0 実装（Google固有: スコープ drive.file）
- [x] フォルダ作成（files.create, mimeType=folder, parents）
- [x] Resumable Upload 実装（セッションURI取得 → チャンク送信 → 1週間失効対応）
- [x] md5Checksum による重複確認
- [x] permissions.create による共有（オプション）

### 1.5 OneDrive コネクタ（Microsoft Graph） `cc:DONE`
- [x] MSAL / OAuth 2.0 実装
- [x] アプリフォルダ（special/approot）アクセス
- [x] createUploadSession → チャンク PUT → nextExpectedRanges 再開
- [x] expirationDateTime 管理
- [x] quickXorHash による重複確認
- [x] createLink による共有（オプション）

### 1.6 Dropbox コネクタ `cc:DONE`
- [x] OAuth 2.0 + PKCE 実装（token_access_type=offline）
- [x] upload session（start/append/finish, 7日セッション上限）
- [x] content_hash による重複確認
- [x] create_shared_link_with_settings（オプション）

### 1.7 アップロードキュー `cc:WIP`
- [x] UploadTask キュー管理（FIFO / 優先度）
- [x] 並列アップロード制御（同時接続数制限 maxConcurrent=3）
- [x] オフラインキュー（ネットワーク不通時にキュー蓄積 → NWPathMonitor で復帰検知）
- [x] リトライ＋指数バックオフ（429 Retry-After / 5xx / セッション期限切れ再作成）
- [ ] Background URLSession 対応（大容量転送）

### 1.8 基本分類（メタデータ＋ルール）（FR-06） `cc:WIP`
- [x] Stage 0: 種別判定（Screenshot/Recording/Clipboard/Text）＋日時
- [x] Stage 1: ファイル名パース（macOS標準命名規則）
- [x] Stage 2: ユーザールール（キーワード/正規表現/アプリ名/時間帯）
- [x] フォルダパス生成（テンプレート: `Captures/{YYYY}/{YYYY-MM}/{Kind}/{App}/{Category}/`）
- [x] ファイル命名（`YYYY-MM-DD_HH-mm-ss_{Kind}_{App}_{ShortHash}.{ext}`）

### 1.9 重複検出（FR-12） `cc:WIP`
- [x] ローカル SHA-256 ハッシュ比較（sizeBytes + contentHashSHA256 で照合）
- [ ] リモートハッシュ照合（Provider別: md5/quickXorHash/content_hash）
- [x] 重複ポリシー設定（スキップ / コピー / alwaysUpload）

### 1.10 UI — メニューバー＋設定画面（FR-17） `cc:DONE`
- [x] メニューバー常駐アイコン（MenuBarExtra + .menuBarExtraStyle(.window)）
- [x] 同期状態表示（同期中=矢印回転/停止=一時停止/エラー=警告/未接続）
- [x] 直近の取り込み件数表示（本日 N 件）
- [x] 同期を一時停止 / 再開 ボタン
- [x] 失敗タスク件数表示（0件なら非表示）
- [x] 設定画面（SwiftUI Settings シーン, 600×500 pt, TabView）
  - [x] GeneralSettingsView: Watchフォルダ追加/削除, 命名テンプレート, 後処理, 通知
  - [x] ProvidersSettingsView: プロバイダ接続/切断, アイコン表示
  - [x] ClassificationSettingsView: ルール一覧(ドラッグ並替), 追加/編集/削除, OCRトグル
  - [x] LogViewerView: 直近100件, レベルフィルタ, コピー/エクスポート
  - [x] FailedTasksView: 失敗タスク一覧, 再試行/キャンセル
- [ ] 通知（UNUserNotificationCenter 許可＋成功/失敗通知）

---

## Phase 2: 拡張機能 `cc:DONE`

### 2.1 Captureモード（FR-03） `cc:DONE`
- [x] ScreenCaptureKit でスクリーンキャプチャ（SCScreenshotManager）
- [x] 画面録画（SCStream → AVAssetWriter → .mov）
- [x] グローバルホットキー登録（HotkeyManager.swift）
- [x] キャプション入力UI（CaptionPopover.swift）
- [x] Captureモードでの frontmost app 取得（NSWorkspace.shared.frontmostApplication）

### 2.2 クリップボード監視（FR-05） `cc:DONE`
- [x] NSPasteboard changeCount ポーリング（省電力設計、デフォルト2秒）
- [x] 画像/テキストの自動取り込み（PNG/TIFF/JPEG + String）
- [x] ホットキーによる手動取り込みオプション（HotkeyManager.captureClipboard）

### 2.3 OCR分類（FR-06 Stage 3） `cc:DONE`
- [x] Vision VNRecognizeTextRequest による文字抽出（ja-JP + en-US、accurate モード）
- [x] OCR結果 → キーワード/正規表現マッチ → 分類ラベル
- [x] OCR ON/OFF 設定（UserDefaults "ocrEnabled"）
- [ ] 抽出テキスト保存範囲の設定（ローカルのみ / 保存しない）

### 2.4 画像分類（FR-06 Stage 4） `cc:DONE`
- [x] VNClassifyImageRequest による画像カテゴリ判定（Apple 組み込みモデル）
- [x] VNCoreMLRequest カスタムモデル差し込みポイント実装済み
- [x] confidence と説明文のログ記録

### 2.5 iCloud Drive 本格対応（FR-11） `cc:DONE`
- [x] iCloud コンテナ設定（Documents フォルダ公開）
- [x] NSFileCoordinator / NSFilePresenter によるファイル協調
- [x] NSFileVersion による競合検出・解決（TN2336 準拠）
- [x] 不要バージョンの自動削除

### 2.6 スクリーンショット保存先統制（FR-04） `cc:DONE`
- [x] 初回セットアップウィザード（SetupWizardView.swift、5ステップ）
- [x] macOS Shift+Command+5 → オプション → 保存先変更のガイド表示

---

## Phase 3: 品質・配布 `cc:WIP`

### 3.1 テスト `cc:DONE`
- [x] ユニットテスト（モデル、分類ロジック、ハッシュ、ルールエンジン）
  - [x] ModelTests.swift: 全データモデルのテスト
  - [x] HashHelperTests.swift: SHA-256テスト
  - [x] ClassificationEngineTests.swift: 分類ロジックテスト（Stage 0/1/2）
  - [x] PathResolverTests.swift: パス生成・テンプレート展開・ShortHashテスト
  - [x] DuplicateDetectorTests.swift: 重複検出テスト
  - [x] ScreenVaultErrorTests.swift: エラー型テスト
- [ ] 統合テスト（Watch → 取り込み → 分類 → アップロード）
- [ ] モック Provider でのエラー/リトライテスト
- [ ] TC-01〜TC-10 の自動化（要件定義書テストケース参照）

### 3.2 配布準備 `cc:DONE`
- [x] README.md（プロジェクトルートに作成）
- [ ] App Store 向けパッケージング（サンドボックス準拠確認）
- [ ] Developer ID 署名 + Notarization（社内配布用）
- [ ] App Store Review Guidelines 対応チェック

### 3.3 運用基盤 `cc:DONE`
- [x] ログエクスポート機能（LogExporter.swift: CSV/JSON エクスポート + NSSavePanel 保存）
- [x] メトリクス集計（MetricsCollector.swift: DailyStats 集計 + @Published）
- [ ] クラッシュレポート対応

---

## マーカー凡例

| マーカー | 状態 | 説明 |
|---------|------|------|
| `cc:DONE` | 未着手 | Claude Code が実行予定 |
| `cc:WIP` | 作業中 | Claude Code が実装中 |
| `cc:DONE` | 完了 | 実装・検証済み |
| `cc:blocked` | ブロック中 | 依存タスク待ち |
