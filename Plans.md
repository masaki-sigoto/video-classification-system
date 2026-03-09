# Plans.md — ScreenVault 開発計画

> 要件定義書: `Macスクリーンショット等の自動クラウド保存・分類システム 要件定義.md`

## Phase 0: プロジェクト基盤 `cc:TODO`

### 0.1 Xcodeプロジェクト生成 `cc:TODO`
- [ ] xcodegen でプロジェクト生成（project.yml）
- [ ] App Sandbox エンタイトルメント設定
- [ ] Info.plist 基本設定（バンドルID、最小OS等）
- [ ] ディレクトリ構成の作成（CLAUDE.md記載の構成）

### 0.2 データモデル（SwiftData） `cc:TODO`
- [ ] Asset モデル（kind, source_mode, content_hash_sha256, captured_at, frontmost_app, caption_text, ocr_text, size_bytes）
- [ ] UploadTask モデル（asset_id, account_id, status, retry_count, next_retry_at, upload_session_ref）
- [ ] ProviderAccount モデル（provider_type, user_display, scope_level）
- [ ] OAuthToken モデル（access_token_ref → Keychain参照, refresh_token_ref, expires_at）
- [ ] RemoteFolderCache モデル（folder_path_key → remote_folder_id）
- [ ] Rule / RuleAction モデル
- [ ] AssetTag モデル（tag, confidence）
- [ ] AuditLog モデル（event_type, entity_id, message_redacted）

### 0.3 共通基盤 `cc:TODO`
- [ ] OSLog Logger ラッパー（サブシステム・カテゴリ定義）
- [ ] Keychain ヘルパー（トークン CRUD）
- [ ] CryptoKit SHA-256 ハッシュユーティリティ
- [ ] Security-Scoped Bookmark 管理（保存/復元/アクセス）
- [ ] エラー型定義（ScreenVaultError enum）

---

## Phase 1: MVP — Watchモード ＋ クラウド連携（3社） `cc:TODO`

### 1.1 Watchモード（FR-02） `cc:TODO`
- [ ] FSEvents によるフォルダ監視（DispatchSource.makeFileSystemObjectSource or FileManager eventsを利用）
- [ ] ファイル安定化検出（サイズ変化停止 + ファイルロック解除の確認）
- [ ] Asset 生成 + メタデータ抽出（UTI判定、サイズ、日時）
- [ ] Security-Scoped Bookmark で Watch フォルダの永続アクセス

### 1.2 OAuth 2.0 + PKCE 共通基盤（FR 認証） `cc:TODO`
- [ ] OAuth フロー共通実装（ASWebAuthenticationSession or システムブラウザ）
- [ ] PKCE チャレンジ生成（code_verifier / code_challenge）
- [ ] トークン管理（アクセストークン更新、リフレッシュ、Keychain格納）
- [ ] 認証状態の監視と再認可フロー

### 1.3 Provider Connector 抽象層 `cc:TODO`
- [ ] ProviderConnector プロトコル定義
  - `authenticate()`, `ensureFolder(pathComponents:)`, `uploadResumable(asset:remoteFolderId:)`, `setSharing(remoteFileId:policy:)`, `getRemoteHashes(remoteFileId:)`
- [ ] ProviderManager（アカウント一覧、接続/切断、アクティブプロバイダ管理）

### 1.4 Google Drive コネクタ `cc:TODO`
- [ ] OAuth 2.0 実装（Google固有: スコープ drive.file）
- [ ] フォルダ作成（files.create, mimeType=folder, parents）
- [ ] Resumable Upload 実装（セッションURI取得 → チャンク送信 → 1週間失効対応）
- [ ] md5Checksum による重複確認
- [ ] permissions.create による共有（オプション）

### 1.5 OneDrive コネクタ（Microsoft Graph） `cc:TODO`
- [ ] MSAL / OAuth 2.0 実装
- [ ] アプリフォルダ（special/approot）アクセス
- [ ] createUploadSession → チャンク PUT → nextExpectedRanges 再開
- [ ] expirationDateTime 管理
- [ ] quickXorHash による重複確認
- [ ] createLink による共有（オプション）

### 1.6 Dropbox コネクタ `cc:TODO`
- [ ] OAuth 2.0 + PKCE 実装（token_access_type=offline）
- [ ] upload session（start/append/finish, 7日セッション上限）
- [ ] content_hash による重複確認
- [ ] create_shared_link_with_settings（オプション）

### 1.7 アップロードキュー `cc:TODO`
- [ ] UploadTask キュー管理（FIFO / 優先度）
- [ ] 並列アップロード制御（同時接続数制限）
- [ ] オフラインキュー（ネットワーク不通時にキュー蓄積 → NWPathMonitor で復帰検知）
- [ ] リトライ＋指数バックオフ（429 Retry-After / 5xx / セッション期限切れ再作成）
- [ ] Background URLSession 対応（大容量転送）

### 1.8 基本分類（メタデータ＋ルール）（FR-06） `cc:TODO`
- [ ] Stage 0: 種別判定（Screenshot/Recording/Clipboard/Text）＋日時
- [ ] Stage 1: ファイル名パース（macOS標準命名規則）
- [ ] Stage 2: ユーザールール（キーワード/正規表現/アプリ名/時間帯）
- [ ] フォルダパス生成（テンプレート: `{Root}/Captures/YYYY/YYYY-MM/{Kind}/{App}/{Category}/`）
- [ ] ファイル命名（`YYYY-MM-DD_HH-mm-ss_{Kind}_{App}_{ShortHash}.{ext}`）

### 1.9 重複検出（FR-12） `cc:TODO`
- [ ] ローカル SHA-256 ハッシュ比較
- [ ] リモートハッシュ照合（Provider別: md5/quickXorHash/content_hash）
- [ ] 重複ポリシー設定（スキップ / コピー / 新規）

### 1.10 UI — メニューバー＋設定画面（FR-17） `cc:TODO`
- [ ] メニューバー常駐アイコン（NSStatusItem, SwiftUI Menu）
- [ ] 同期状態表示（同期中/停止/エラー/未接続）
- [ ] 設定画面（SwiftUI Window）
  - Provider接続管理
  - Watchフォルダ追加/削除
  - 分類ルール設定
  - フォルダ命名テンプレート
- [ ] 通知（UNUserNotificationCenter 許可＋成功/失敗通知）
- [ ] 失敗タスク一覧（手動再試行/停止）
- [ ] 監査ログ閲覧（直近N件）

---

## Phase 2: 拡張機能 `cc:TODO`

### 2.1 Captureモード（FR-03） `cc:TODO`
- [ ] ScreenCaptureKit でスクリーンキャプチャ
- [ ] 画面録画（ストリーム → エンコード → チャンクアップロード）
- [ ] グローバルホットキー登録
- [ ] キャプション入力UI（ポップオーバー）
- [ ] Captureモードでの frontmost app 取得

### 2.2 クリップボード監視（FR-05） `cc:TODO`
- [ ] NSPasteboard changeCount ポーリング（省電力設計）
- [ ] 画像/テキストの自動取り込み
- [ ] ホットキーによる手動取り込みオプション

### 2.3 OCR分類（FR-06 Stage 3） `cc:TODO`
- [ ] Vision VNRecognizeTextRequest による文字抽出
- [ ] OCR結果 → キーワード/正規表現マッチ → 分類ラベル
- [ ] OCR ON/OFF 設定（プライバシー配慮）
- [ ] 抽出テキスト保存範囲の設定（ローカルのみ / 保存しない）

### 2.4 画像分類（FR-06 Stage 4） `cc:TODO`
- [ ] VNCoreMLRequest による画像カテゴリ判定
- [ ] Create ML での分類モデル作成（図/写真/コード等）
- [ ] confidence と説明文のログ記録

### 2.5 iCloud Drive 本格対応（FR-11） `cc:TODO`
- [ ] iCloud コンテナ設定（Documents フォルダ公開）
- [ ] NSFileCoordinator / NSFilePresenter によるファイル協調
- [ ] NSFileVersion による競合検出・解決（TN2336 準拠）
- [ ] 不要バージョンの自動削除

### 2.6 スクリーンショット保存先統制（FR-04） `cc:TODO`
- [ ] 初回セットアップウィザード
- [ ] macOS Shift+Command+5 → オプション → 保存先変更のガイド表示

---

## Phase 3: 品質・配布 `cc:TODO`

### 3.1 テスト `cc:TODO`
- [ ] ユニットテスト（モデル、分類ロジック、ハッシュ、ルールエンジン）
- [ ] 統合テスト（Watch → 取り込み → 分類 → アップロード）
- [ ] モック Provider でのエラー/リトライテスト
- [ ] TC-01〜TC-10 の自動化（要件定義書テストケース参照）

### 3.2 配布準備 `cc:TODO`
- [ ] App Store 向けパッケージング（サンドボックス準拠確認）
- [ ] Developer ID 署名 + Notarization（社内配布用）
- [ ] App Store Review Guidelines 対応チェック

### 3.3 運用基盤 `cc:TODO`
- [ ] ログエクスポート機能
- [ ] メトリクス集計（取り込み件数、アップロード成功率等）
- [ ] クラッシュレポート対応

---

## マーカー凡例

| マーカー | 状態 | 説明 |
|---------|------|------|
| `cc:TODO` | 未着手 | Claude Code が実行予定 |
| `cc:WIP` | 作業中 | Claude Code が実装中 |
| `cc:DONE` | 完了 | 実装・検証済み |
| `cc:blocked` | ブロック中 | 依存タスク待ち |
