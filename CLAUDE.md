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
