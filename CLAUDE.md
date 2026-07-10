# LearnLanguage — 開発ガイド（Claude Code 向け）

英語（将来多言語）学習アプリ。URL の記事を AI でレベル別に書き換え、イラスト生成・読み上げ・
履歴保存する。iOS 26+ / macOS 26+（ネイティブマルチプラットフォーム）、SwiftUI +
`@Observable` + SwiftData、xcodegen（`project.yml` が正）。
機能一覧・セットアップ手順は `README.md` を参照。

作業前に **`docs/ARCHITECTURE.md`** を読むこと。レイヤと依存方向、破ってはいけない規範
（ローカライズは key ベース、Gemini アクセスは `GeminiClient` 経由のみ、等）をまとめてある。

過去の大規模リファクタリング（構造の経緯・比較検討した代替案）は `docs/REFACTORING_PLAN.md` を参照。

## ビルド・テスト

```sh
xcodegen generate   # project.yml を編集/ファイル追加したら必ず実行（.xcodeproj は生成物・gitignore対象）
xcodebuild -project LearnLanguage.xcodeproj -scheme LearnLanguage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
xcodebuild -project LearnLanguage.xcodeproj -scheme LearnLanguage \
  -destination 'platform=macOS' test   # macOS もネイティブ対応。変更後は両方でビルド確認する
```

FoundationModels・画像生成・WKWebView 描画は Simulator で完全には検証できない。
関連機能を変更したら実機での確認を優先する。
SourceKit（エディタ診断）が大量の `Cannot find ... in scope` を出すことがあるがノイズ。
判断は xcodebuild の結果で行う。

## このプロジェクト固有の注意点

- SwiftData のスキーマ変更（`Persistence/Models.swift`）は他の変更と混ぜず単独コミットにする。
- ユーザー向け文言（エラー・ログ・UI）は日英対応が前提。`Localizable.xcstrings` にキーを足すこと。
- `GenerationQueue` に手を入れるときは `docs/ARCHITECTURE.md` の責務分担（QueueStore /
  ArticleLogger / BatchProcessor）に従う。
- `@AppStorage` の設定キーを増やしたら `SettingsCloudSync.syncedKeys` にも追加する（iCloud 同期対象）。
- **iOS / macOS 差分は `Shared/PlatformCompat.swift` に集約**（`Image(data:)`、iOS 専用 modifier の
  no-op 化）。iOS 専用 API を使うときは安易に `#if` を散らさず、まず PlatformCompat のヘルパを検討する。
- エンタイトルメントはプラットフォーム別（iOS: `LearnLanguage.entitlements` / macOS:
  `LearnLanguage-macOS.entitlements`）。macOS は App Sandbox 必須（TestFlight/Mac App Store 配布）で、
  `aps-environment` のキー名が `com.apple.developer.` プレフィックス付きになる点が iOS と異なる。
  App Group は iOS のみ（macOS は Share Extension 非対応・`SharedInbox` は macOS で常に no-op）。

## リリース（Xcode Cloud → TestFlight）

DLNAviewer と同じ方式。ビルドは **Xcode Cloud**、トリガーは **タグの push**
（Start Condition は「Any tags」。`v*` のカスタムパターン指定だと ref が列挙されず
手動ビルドもできなかったため Any tags にしている。タグは `make release-tag` 経由の
`v<MARKETING_VERSION>` 形式しか作らない運用なので実質同じ）。

- `.xcodeproj` は未コミットなので、`ci_scripts/ci_post_clone.sh` がクローン後に
  `xcodegen generate` する（これが無いと Xcode Cloud がプロジェクトを見つけられない）。
- ワークフローの **scheme は `LearnLanguage`**（App Store Connect 側の GUI で設定。リポジトリ内には無い）。
- **macOS 版も同じワークフロー・同じタグ**でビルドする（Archive - macOS アクションを ASC 側で追加済み
  の前提。Mac へのインストールは Mac 用 TestFlight アプリ経由・自動更新もそちら任せで、
  アプリ内に更新チェック機能は持たない）。
- バージョンは `project.yml` の 2 つの値で管理: `MARKETING_VERSION`（表示版・タグ採番用）と
  `CURRENT_PROJECT_VERSION`（ビルド番号）。タグのフォーマットは **`v<MARKETING_VERSION>`**。

### リリース手順

1. **ビルド番号を +1**: `project.yml` の `CURRENT_PROJECT_VERSION` を上げる（新ビルド配布のたびに必須。
   同一だと App Store Connect に弾かれる: ITMS-90382）。
2. **表示バージョンを変える場合**は `MARKETING_VERSION` も更新。
3. 変更をコミットして `main` に push。
4. **`make release-tag`** を実行（手動 `git tag`/`git push` は使わない）。ブランチが `main`・
   作業ツリーがクリーン・`origin/main` と同期済み・タグ未作成、をすべて満たさないと中断する。
   タグ push が Xcode Cloud のビルドトリガーになる。
