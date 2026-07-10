# LearnLanguage — 開発ガイド（Claude Code 向け）

英語（将来多言語）学習アプリ。URL の記事を AI でレベル別に書き換え、イラスト生成・読み上げ・
履歴保存する。iOS 26+、SwiftUI + `@Observable` + SwiftData、xcodegen（`project.yml` が正）。
機能一覧・セットアップ手順は `README.md` を参照。

作業前に **`docs/ARCHITECTURE.md`** を読むこと。レイヤと依存方向、破ってはいけない規範
（ローカライズは key ベース、Gemini アクセスは `GeminiClient` 経由のみ、等）をまとめてある。

過去の大規模リファクタリング（構造の経緯・比較検討した代替案）は `docs/REFACTORING_PLAN.md` を参照。

## ビルド・テスト

```sh
xcodegen generate   # project.yml を編集/ファイル追加したら必ず実行（.xcodeproj は生成物・gitignore対象）
xcodebuild -project LearnLanguage.xcodeproj -scheme LearnLanguage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

FoundationModels・画像生成・WKWebView 描画は Simulator で完全には検証できない。
関連機能を変更したら実機での確認を優先する。

## このプロジェクト固有の注意点

- SwiftData のスキーマ変更（`Persistence/Models.swift`）は他の変更と混ぜず単独コミットにする。
- ユーザー向け文言（エラー・ログ・UI）は日英対応が前提。`Localizable.xcstrings` にキーを足すこと。
- `GenerationQueue` に手を入れるときは `docs/ARCHITECTURE.md` の責務分担（QueueStore /
  ArticleLogger / BatchProcessor）に従う。
- `@AppStorage` の設定キーを増やしたら `SettingsCloudSync.syncedKeys` にも追加する（iCloud 同期対象）。

## リリース（Xcode Cloud → TestFlight）

DLNAviewer と同じ方式。ビルドは **Xcode Cloud**、トリガーは **`v*` タグの push**。

- `.xcodeproj` は未コミットなので、`ci_scripts/ci_post_clone.sh` がクローン後に
  `xcodegen generate` する（これが無いと Xcode Cloud がプロジェクトを見つけられない）。
- ワークフローの **scheme は `LearnLanguage`**（App Store Connect 側の GUI で設定。リポジトリ内には無い）。
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
