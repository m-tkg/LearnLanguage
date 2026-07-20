# LearnLanguage

記事 URL を渡すと、AI が語彙レベルに合わせて本文を書き換え、内容を説明するイラストを付けた
語学教材を自動生成する iOS/iPadOS アプリ。読み上げ・母語訳・用語集付きで、生成した教材は
端末内に蓄積される。まずは英語学習向け（将来多言語対応を見据えた設計）。

> **自分のアカウントでビルドする場合**は、先に `Config/Local.xcconfig` を作って
> Team ID と Bundle ID を自分の値に差し替える必要がある。
> 手順は[こちら](#自分のアカウントでビルドする)。

## 主な機能

- **教材生成**: 記事 URL（アプリ内・シェアシートのどちらからでも）→ 本文抽出 →
  レベル別書き換え（初級/中級/上級/オリジナル）→ 3〜4 セグメントに分割 → セグメントごとにイラスト生成
- **学習画面**: イラスト＋本文（レベル超過語はハイライト＋用語集）、読み上げ（速度は記事ごとに保存）、
  母語へのワンタップ翻訳（オンデバイス）
- **記事一覧**: 生成の進捗表示・並び替え・お気に入り・失敗時の再実行・処理ログ（長押し）
- **日英 UI**: 端末の言語設定に追従

## 動作環境

- iOS 26+ / Apple Intelligence 対応端末（オンデバイス書き換え・翻訳を使う場合）
- Xcode 27+ / [xcodegen](https://github.com/yonaskolb/XcodeGen)
- Mac で使う場合は Apple Silicon Mac 上で **iPad 版をそのまま実行**する（Designed for iPad。
  Mac ネイティブ版は作らない方針。TestFlight for Mac の「iPhone および iPad App」から
  インストールできる）

## セットアップ

```sh
brew install xcodegen   # 未導入の場合
xcodegen generate       # project.yml から .xcodeproj を生成（.xcodeproj はコミットしない）
open LearnLanguage.xcodeproj
```

### 自分のアカウントでビルドする

`Config/Signing.xcconfig` は編集せず、`Config/Local.xcconfig` を作って上書きする。

    cp Config/Local.xcconfig.sample Config/Local.xcconfig
    # DEVELOPMENT_TEAM と APP_BUNDLE_ID を自分の値に書き換える

`Config/Local.xcconfig` は .gitignore 済みなので、追跡ファイルの差分は出ない。

ただし App Group（`group.com.mtkg.LearnLanguage`）・iCloud コンテナ
（`iCloud.com.mtkg.LearnLanguage`）は entitlements 2 ファイルと `SharedInbox.appGroupID` に
ハードコードされたままのため、引き続き手動で自分の識別子に読み替える必要がある。
このアプリは App Groups / CloudKit を使うため、無料の Personal Team ではビルドできない
（要 Apple Developer Program 加入）。

### Apple Developer Portal の初回設定（capability）

このアプリは以下の capability を使う。**Xcode の自動署名で実機ビルドすれば基本的にすべて自動登録される**が、
登録状況は [Identifiers](https://developer.apple.com/account/resources/identifiers/list) で確認・手動修正できる。

| 対象 | capability | 用途 |
|---|---|---|
| `com.mtkg.LearnLanguage` | App Groups（`group.com.mtkg.LearnLanguage`） | シェアシート → 本体への URL 受け渡し |
| 〃 | iCloud: Key-Value storage | 設定（母語・レベル・プロバイダ選択等）の端末間同期 |
| 〃 | iCloud: CloudKit（コンテナ `iCloud.com.mtkg.LearnLanguage`） | 記事・画像の端末間同期 |
| `com.mtkg.LearnLanguage.ShareExtension` | App Groups（同上） | 〃 |

- iCloud コンテナの新規登録で「is not available」エラーが出る場合は、**既に登録済み**
  （自動署名が作成した）の可能性が高い。Identifiers 左上のドロップダウンを「iCloud Containers」に
  切り替えて一覧を確認する。
- API キーの同期は iCloud キーチェーン（`kSecAttrSynchronizable`）で、portal 側の設定は不要。

### CloudKit スキーマの Production デプロイ（TestFlight 前に必須）

記事同期（SwiftData + CloudKit）のスキーマは **Development 環境に自動作成されるだけ**で、
TestFlight / App Store ビルドが使う **Production 環境には手動デプロイしない限り反映されない**。
忘れると「Xcode からのビルドでは同期するのに TestFlight 版では同期しない」状態になる。

1. Xcode から実機（iCloud サインイン済み）でアプリを起動し、記事がある状態で 1〜2 分待つ
   → スキーマが Development に自動作成される
2. [CloudKit Console](https://icloud.developer.apple.com) → `iCloud.com.mtkg.LearnLanguage` →
   **Schema → Record Types** に `CD_LearningArticle` 等が並んでいることを確認
3. **「Deploy Schema Changes to Production」** を実行（差分を確認して Deploy）

**SwiftData のモデルにプロパティを追加するたびに、リリース前に手順 3 の再デプロイが必要**。
Production へのデプロイは取り消せない（追加のみ可・削除不可）。

### API キー（BYOK・すべて端末の Keychain にのみ保存）

| 用途 | プロバイダ | 備考 |
|---|---|---|
| 本文の書き換え | Gemini（既定）または オンデバイス | Gemini はテキスト無料枠あり。[Google AI Studio](https://aistudio.google.com/apikey) でキー取得 |
| イラスト生成 | Pollinations（既定・キー不要）/ Cloudflare Workers AI / Gemini | Cloudflare は無料枠が広く安定（Account ID + Workers AI 権限の API トークン）。Gemini 画像は実質有料 |

すべてアプリ内の設定画面から入力する。

## リリース（Xcode Cloud → TestFlight）

ビルドは Xcode Cloud、トリガーは **タグの push**。日常のリリース手順：

1. `project.yml` の `CURRENT_PROJECT_VERSION` を +1（表示バージョンを変えるなら
   `MARKETING_VERSION` も）。同一ビルド番号は App Store Connect に弾かれる（ITMS-90382）
2. コミットして `main` へ push
3. `make release-tag` を実行 → `v<MARKETING_VERSION>` タグが push され、Xcode Cloud が
   ビルド → TestFlight 配布する（ブランチ・作業ツリー・タグ重複の安全チェック付き）

### Xcode Cloud ワークフローの初回設定（App Store Connect 側・リポジトリ外）

1. App Store Connect にアプリレコードを作成（Bundle ID `com.mtkg.LearnLanguage`）
2. Xcode の Product > Xcode Cloud > Create Workflow で GitHub リポジトリを接続
3. ワークフロー設定:
   - **Scheme: `LearnLanguage`**
   - **Start Condition: Tag Changes →「Any tags」**（カスタムパターン `v*` は ref が列挙されず
     手動ビルドもできない事象があったため Any tags を使う。タグは `make release-tag` 経由の
     `v<MARKETING_VERSION>` 形式しか作らない運用なので実質同じ）
   - Action: Archive（iOS）/ Post-Action: TestFlight
4. `.xcodeproj` は未コミットのため、`ci_scripts/ci_post_clone.sh` がクローン直後に
   xcodegen をインストールして生成する（リポジトリに含まれており追加設定は不要）
5. 輸出コンプライアンスは `project.yml` で宣言済み（HTTPS のみ使用・免除）のため、
   ビルドごとの Missing Compliance 回答は不要

## ビルド・テスト

```sh
xcodebuild -project LearnLanguage.xcodeproj -scheme LearnLanguage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

FoundationModels・画像生成・WKWebView 描画は Simulator で完全には検証できないため、
関連機能の確認は実機を優先する。

## ドキュメント

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — レイヤ構成・依存方向・開発規範
- [docs/REFACTORING_PLAN.md](docs/REFACTORING_PLAN.md) — 大規模リファクタリングの経緯と判断記録
- [CLAUDE.md](CLAUDE.md) — AI 支援開発（Claude Code）向けのプロジェクトガイド
