# LearnLanguage アーキテクチャ

英語（将来多言語）学習アプリ。URL の記事を Gemini/FoundationModels でレベル別に書き換え、
イラスト生成・読み上げ・履歴保存する。iOS 26+、SwiftUI + `@Observable` + SwiftData。

## レイヤと依存方向

```
Features/   画面（View + 必要に応じ @Observable コントローラ）
    ↓
Pipeline/   生成キューのオーケストレーション（GenerationQueue とその協力者）
    ↓
Services/   外部 I/O・フレームワーク依存の実装（Extraction/Generation/Imaging/Speech/Gemini）
    ↓
Domain/     フレームワーク非依存の値型（Entities）と protocol（Ports）
    ↓
Shared/     横断ユーティリティ（KeychainStore, IllustrationPrompt, GlossaryHighlighter 等）
    ↑
Persistence/ SwiftData の @Model（Features/Pipeline/Services 全層から参照される）
```

**依存は上から下へ一方向。逆流禁止。** 具体的には：
- `Services/Extraction` は `Services/Generation` の設定（`GeminiModel.current` 等）を直接参照しない。
  どのモデルを使うかは呼び出し側（`ArticleContentExtractor.extract`、編成層）が解決してから
  Fetcher へ**引数として**渡す（`GeminiURLContextFetcher.fetch(url:model:)`）。
- `Domain/Ports` の protocol（`ContentExtracting` / `TextRewriting` / `BatchRewriting` /
  `IllustrationGenerating`）が Services の実装と Pipeline の間の境界線。`GenerationQueue` は
  具象型ではなく protocol 越しにサービスを呼ぶため、テストでモックに差し替えられる。

## 主要コンポーネント

| コンポーネント | 役割 |
|---|---|
| `Pipeline/GenerationQueue` | 公開 API（enqueue/resumePending/retry/processIfNeeded）と直列処理ループのみ |
| `Pipeline/QueueStore` | SwiftData クエリ（次のバッチ取得・ステータス遷移）を一元化 |
| `Pipeline/ArticleLogger` | 処理ログの記録（`ArticleLogEntry` 生成） |
| `Pipeline/BatchProcessor` | 1バッチの実処理（抽出→書き換え→イラスト生成の3フェーズ） |
| `Services/Extraction/ArticleContentExtractor` | 抽出の編成のみ。実際の取得は 4 つの Fetcher の段階的フォールバック |
| `Services/Gemini/GeminiClient` | Gemini REST API への唯一の窓口（認証・リトライ・エラー分類を一元化） |
| `Services/Generation/RewriterFactory`, `Services/Imaging/IllustratorFactory` | 設定（AppStorage）に応じて実サービスを返す Factory |

## 規範（ここを外れたら要修正のサイン）

1. **ユーザー向け文言は key ベースでローカライズする。**
   - 処理ログ（`ArticleLogEntry`）は `messageKey` + `messageArgs`（`%@` 埋め込み）で保存し、
     表示時に `localizedMessage` が `String(localized:)` で解決する。
   - 保存済みエラー（`LearningArticle.failureReason` / `ArticleSegment.imageFailureReason`）は
     スキーマを増やさず、**固定文（引数なし）の日本語確定文をそのまま `Localizable.xcstrings`
     のキーとして登録**し、表示側で `Text(LocalizedStringKey(reason))` に通す軽量方式を採用。
     動的引数を含む文言（HTTP ステータスコード等）は対象外で日本語のままフォールバックする
     （実害は小さいと判断）。新しいエラー文言を追加したら `Localizable.xcstrings` に英訳を足すこと。
   - UI の固定文言（タイトル・ボタン等）も同様に `LocalizedStringKey` / xcstrings 経由。
     `Text(変数)` や三項演算子で `String` 化すると自動ローカライズされない点に注意
     （`Text(LocalizedStringKey(x))` または三項の両辺をそれぞれ `LocalizedStringKey("...")` にする）。

2. **Gemini API へのアクセスは `GeminiClient` 経由のみ。** `generativelanguage.googleapis.com` を
   直接叩くコードを増やさない（過去に 3 箇所で重複し、429/PerDay/認証エラーの扱いが食い違った）。
   新しい Gemini エンドポイントを使う場合も `GeminiClient.send(model:body:apiKey:)` を使い、
   リクエストボディの `Encodable` 構築とレスポンスの意味解釈だけを呼び出し側に書く。

3. **`GenerationQueue` へ機能を足すときは、まず「どのファイルの責務か」を考える。**
   キューの状態遷移や新しいステータス問い合わせは `QueueStore`、ログの新しい種類は
   `ArticleLogger`、抽出/書き換え/イラストの処理フローの変更は `BatchProcessor`。
   `GenerationQueue` 自体を太らせない。

4. **`GenerationQueue` のテスト（`GenerationQueueTests.swift`）は公開 API のみを叩く。**
   コンストラクタ・`enqueue`・`processIfNeeded` のシグネチャは、内部実装をどう変えても
   互換性を保つ（Phase 5 のリファクタリングで実際にこの制約が守られたことをテスト差分ゼロで確認済み）。

5. **SwiftData のスキーマ変更は他の変更と混ぜない。** 単独コミットにし、可能なら実機で
   既存データからの起動を確認する（旧ビルドでデータ作成 → 新ビルド上書きインストール →
   履歴・画像・ログが残ることを確認）。

6. **モック/テストダブルは使う側の近くに置く。** Services 層に「誰にも呼ばれないモック」を
   ミラーで用意しない（過去に `Shared/Mocks/MockServices.swift` が丸ごと未使用のまま本体
   アプリバイナリに同梱されていた）。`GenerationQueueTests` のように、そのテストが必要とする
   呼び出し回数計測込みのスパイをテストファイル内に定義する方が実用的なことが多い。

## ビルド・テスト

```sh
xcodegen generate   # project.yml からの再生成（LearnLanguage.xcodeproj は gitignore 対象）
xcodebuild -project LearnLanguage.xcodeproj -scheme LearnLanguage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

FoundationModels / 画像生成 / WKWebView 描画は Simulator で完全には検証できないため、
関連機能を変更したら実機での確認を優先する。

## リファクタリング経緯

このアーキテクチャは `docs/REFACTORING_PLAN.md`（Phase 0〜7）で段階的に整理された。
背景・判断理由・比較検討した代替案はそちらを参照。
