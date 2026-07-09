# LearnLanguage リファクタリング計画

作成日: 2026-07-10（コードベース実測: 3,767行 / 39ファイル / テスト53件）

## 0. 現状診断（実測に基づく無駄の棚卸し）

### A. 死んだコード（参照ゼロ・即削除可能）
| 対象 | 場所 | 経緯 |
|---|---|---|
| `GenerationQueue.retryIncomplete()` | Pipeline/GenerationQueue.swift:69 | Pull-to-refresh をステータス更新のみに変更した際に呼び出し元が消滅 |
| `IntelligenceAvailabilityService` 一式（`IntelligenceAvailability` / `IntelligenceAvailabilityProviding` / `StubAvailabilityProvider`） | Services/Availability/（50行）+ Mocks | 書き換え既定が Gemini になり Home の可用性ブロックを撤去した際に孤立。コメントは撤去済みの imagePlaygroundSheet に言及（二重に古い） |
| `ProcessingProgress` | Domain/Entities/Entities.swift:82 | 旧 `ArticleProcessingPipeline`（AsyncStream）撤去時の残骸 |
| `MockSpeaker` | Shared/Mocks/MockServices.swift | 参照ゼロ |
| `Speaking` プロトコル | Domain/Ports/Ports.swift | 実装は `SpeechService` のみ、利用側（ReaderView）は具象型を直接使用。Port として機能していない |

### B. 重複（同じ知識が複数箇所に存在）
| 対象 | 実態 |
|---|---|
| **Gemini HTTP クライアントが3実装** | ①`GeminiRewriter`（retry/backoff・`ErrorEnvelope`+violations/isPerDayLimit・JSONモード）②`ArticleContentExtractor.extractViaGemini`（素の JSONSerialization・リトライなし・PerDay検知なし）③`GeminiIllustrator`（独自の簡易 `ErrorEnvelope`・リトライなし）。**429/PerDay の扱いが場所によって違う**＝バグの温床 |
| `styledPrompt` | PollinationsIllustrator と GeminiIllustrator にほぼ同文が2つ（今回のスタイル調整でも2箇所編集が必要だった） |
| API キー取得+trim | GeminiRewriter / extractViaGemini で同パターンを重複実装 |
| `String(localized: String.LocalizationValue(...))` | GenerationQueue / ShareViewController 等に散在するローカライズ呼び出しパターン |

### C. レイヤ崩れ・責務過多
| 対象 | 問題 |
|---|---|
| `ArticleContentExtractor`（421行・最大ファイル） | 直接取得 / WKWebView 描画 / Gemini url_context / Jina Reader / HTML パース / ブロック検知 / 言語判定 の7責務が1 struct に同居。しかも Extraction 層が `GeminiModel`（Generation の設定）と `KeychainStore` に直接依存 |
| `GenerationQueue`（282行） | キュー管理 / バッチ編成 / 抽出 / 書き換え / イラスト / ログ / sortIndex 採番を1クラスで実施。**依存が全て内部生成（`ArticleContentExtractor()` 直 new・Factory 直呼び）でテスト不能**。実際、キュー系のテストは0件 |
| Services 層の日本語ハードコード | 10ファイル全てにユーザー向け日本語文言が直書き。ログは key+args 方式でローカライズ済みなのに、`failureReason` / `imageFailureReason` / 各エラーは日本語固定＝**英語端末で日本語が出る**（ログ改修と非対称） |
| `ReaderView`（304行） | 画面+4つの private View+翻訳ロジック+イラスト再生成ロジックが1ファイル |
| `Ports.swift` のドキュメント | 「実装は WKWebView + Readability.js」等、撤去済み実装への言及が残存 |

### D. モデル・永続化の澱み
| 対象 | 問題 |
|---|---|
| ステータスのマジック文字列 | `#Predicate` 内に `"queued"` `"processing"` `"failed"` が文字列直書き（requeue / nextQueuedBatch）。enum の rawValue と二重管理 |
| `LearningArticle.translationLanguageCode` | 翻訳先が「設定の現在値」に追従する仕様変更後、このフィールドの役割は「作成時の母語（用語集の訳語言語）」に縮小したがドキュメント未更新 |
| `GlossaryTerm.lemma` | 将来用として定義したが書き込み箇所ゼロ |
| `failureReason: String?` | 確定文字列を保存するためローカライズ不能（ログで解決済みの問題と同型） |

### E. テストの穴
- **GenerationQueue（アプリの心臓部）のテストが0件**。モック群（MockContentExtractor 等）は存在するのに DI がないため注入できず、宝の持ち腐れ
- `SharedInbox` / `ErrorEnvelope`（isPerDayLimit 判定）/ `ArticleLogEntry.localizedMessage` もテストなし
- `ArticleContentExtractor` が「static 関数の集合」になっているのはテスト可能にするための応急処置（設計の歪みがテスト形式に漏れている）

### F. Phase 0 実測で判明した潜在バグ（要調査・本計画のスコープ外）
- **`LearningArticle.isDeleted` は `save()` を跨ぐと `false` に戻る**（実測: `context.delete(x)` 直後は `isDeleted==true` だが、その後 `try context.save()` すると `isDeleted` が `false` に戻る＝SwiftData のオブジェクトが「未追跡」化する模様）。
  `GenerationQueue.processBatch`/`illustrateSegments` は処理の合間に頻繁に `try? modelContext.save()` を呼ぶため、**「イラスト生成中にユーザーが記事を削除した」場合に `!article.isDeleted` ガードが検知できない可能性がある**（削除後の最初の save より後のタイミングでは常に false に見える）。
  実害は「削除したはずの記事の生成が裏で続行され、ゾンビ的にログや画像が書き込まれる」程度で致命的ではないが、Phase 5（GenerationQueue 分割）で本格調査し、必要なら「削除済みかどうかは該当 persistentModelID の存在有無を都度 fetch で確認する」等の確実な判定に置き換える。

---

## 1. 方針の選定

### 進め方の比較
| 案 | 内容 | メリット | デメリット |
|---|---|---|---|
| **案1: ボトムアップ段階改修（採用）** | 安全網→削除→重複統合→分解、の順に小さく刻む | 各フェーズ後もアプリは常に動く・テスト常時 green・途中中断可能 | 全体像の刷新は最後まで完了しない |
| 案2: アーキテクチャ一新（例: 全面 DI コンテナ導入） | 理想構造を先に作り移植 | 最終形が綺麗 | 長期間ビルドが壊れる・個人開発の規模に過剰 |
| 案3: 気づいたところから随時 | 計画なし | 着手が軽い | 今回の依頼（計画的な完全リファクタリング）に反する。中途半端に終わる実績パターン |

**案1を採用する理由**: このアプリは実機で日常使用中であり、「常に出荷可能」を維持する価値が高い。また各改修が独立コミットになるため、問題発生時に `git bisect` で即座に原因フェーズを特定できる。

### 案1が破綻する未来
- **SwiftData のスキーマ変更を伴う改修（Phase 7）を他と混ぜた場合**: マイグレーション失敗はストア再作成（=履歴消失）に直結する。→ Phase 7 だけは独立コミット+実機での移行確認を必須とする
- 途中で大型機能追加が割り込み、リファクタ済み/未済みの構造が長期混在した場合 → フェーズ間に機能追加する際は「そのフェーズの新規範に従う」ルールで運用する

### 全フェーズ共通ルール
1. **1フェーズ=1〜数コミット。フェーズ完了ごとに全テスト green + 実機スモーク**（記事追加→生成→閲覧→読み上げ）
2. 挙動変更なし（Phase 3 の文言ローカライズのみ例外・明示）
3. 削除は「参照ゼロをコマンドで確認してから」（`grep -rn <symbol>`）
4. t_wada 流: **Phase 0 で安全網を張ってから**構造を触る。リファクタ中にテストを変更しない（テストが仕様）

---

## 2. フェーズ計画

### Phase 0: 安全網の構築（テストで現行挙動を固定） ✅ 完了
**目的**: 最重要ロジックに特性化テスト（characterization tests）を張り、以降のフェーズの回帰を検出可能にする。

- `GenerationQueue` に **最小限の DI を導入**（コンストラクタで extractor / rewriter / illustrator の生成クロージャを受け取り、既定値は現行の Factory 呼び出し。呼び出し側の変更なし）
  - これは Phase 5 の先取りではなく、テストを書くための最小変更（メソッド分割はしない）
- in-memory `ModelContainer` + 既存 `MockContentExtractor` / `MockTextRewriter` / `MockIllustrator` を使い、以下を固定:
  - enqueue → completed の全遷移（status / segments / logs / sortIndex）
  - 抽出失敗 → failed + failureReason
  - 書き換え失敗（throw）→ 対象記事のみ failed、他は継続
  - **再開の冪等性**: segments 済み記事の再処理で抽出/書き換えが呼ばれない・ready イラストを再生成しない（モックに呼び出しカウンタを付与）
  - 削除された記事のスキップ
- `SharedInbox`（App Group が使えないテスト環境用に suite 名を注入可能に）: append→drain→空
- `ErrorEnvelope`: 実際の 429 JSON フィクスチャで `retryAfter` / `isPerDayLimit` のデコードを固定
- `ArticleLogEntry.localizedMessage`: key+args のフォーマット確認

**完了条件**: テスト 53件 → 約70件。カバレッジの中心が「純ロジック」から「オーケストレーション」へ拡大。
**リスク**: 低（プロダクションコードの変更は DI 用イニシャライザ引数の追加のみ）

---

### Phase 1: 死んだコードの削除 ✅ 完了
**目的**: 考慮対象を減らし、以降のフェーズを軽くする。

削除対象（すべて参照ゼロ確認済み・上記 0-A）:
- `retryIncomplete()`（`requeue` は `resumePending` が使うので残す）
- `Services/Availability/` ディレクトリごと + `StubAvailabilityProvider`
- `ProcessingProgress`
- `MockSpeaker` と `Speaking` プロトコル（`SpeechService` は具象のまま。読み上げをモックしたくなった時に必要十分な protocol を再導入する方が、使われない抽象を維持するより安い）
- `Ports.swift` / 各所の**嘘になったコメント**の修正（「WKWebView + Readability.js」「imagePlaygroundSheet」等）
- `GlossaryTerm.lemma` は **Phase 7 へ先送り**（スキーマ変更を伴うため、ここでは触らない）

**完了条件**: `xcodegen generate` + 全テスト green。行数 約150行減。
**リスク**: 低。

---

### Phase 2: Gemini クライアントの統一 ✅ 完了
**目的**: 3重実装の HTTP クライアントを1つにし、429/PerDay/リトライの挙動を全 API 呼び出しで一貫させる。

#### 設計の比較
| 案 | 内容 | メリット | デメリット |
|---|---|---|---|
| **案A: 薄い `GeminiClient` struct（採用）** | endpoint 構築・`x-goog-api-key`・リトライ/バックオフ・`ErrorEnvelope` 解析・JSONモード切替だけを持つ。プロンプト構築や応答の意味解釈は各サービスに残す | 責務が明確・既存3サービスの差分が最小・テスト容易 | 各サービスに Codable 型は残る |
| 案B: 公式 SDK（GoogleGenerativeAI）導入 | 外部依存に置換 | 実装削減 | 外部 SPM 依存ゼロ方針に反する・url_context 等の対応状況に振り回される |
| 案C: 汎用 HTTPClient 層 | Gemini 非依存の抽象 | 将来他社 API も統一 | 現時点で他社 API は Pollinations（GET 1本）のみ。過剰抽象 |

**案A採用。破綻する未来**: Gemini API の v1beta が廃止され認証/エラー形式が変わる場合 → 変更箇所が GeminiClient 1ファイルに集約されるので、むしろこの改修の価値が上がる。ストリーミング応答を使いたくなった場合は案Aのスコープ外なので、その時に `GeminiClient` へメソッド追加。

作業:
1. `Services/Gemini/GeminiClient.swift` 新設: `send(model:instruction:userText:jsonMode:) async throws -> String` と `sendRaw(model:body:) async throws -> Data`。リトライポリシー（maxAttempts/backoff/retryAfter 尊重/PerDay 即失敗/401・403 即失敗）を内包
2. `GeminiRewriter` → request/sendOnce/ErrorEnvelope を削除し GeminiClient を利用（プロンプト・BatchOutput 解析は残す）
3. `GeminiIllustrator` → 同様（responseModalities: IMAGE は sendRaw 経由）。**これによりイラスト生成にもリトライと PerDay 検知が付く**（現在は無い＝挙動改善だが安全側なので許容）
4. `ArticleContentExtractor.extractViaGemini` → GeminiClient 利用に置換（url_context ツールは sendRaw）
5. `styledPrompt` の共通部を `IllustrationStyle.base` として `Shared/IllustrationPrompt.swift` に統合（Pollinations/Gemini の差分は末尾サフィックスのみに）
6. Phase 0 の ErrorEnvelope テストを GeminiClient のテストとして移設・拡充（401/403、PerDay、retryDelay パース、リトライ上限）

**完了条件**: `generativelanguage.googleapis.com` の出現が GeminiClient 1ファイルのみになる。全テスト green。
**リスク**: 中。API 挙動の一貫化で微妙な差（イラストのリトライ追加）が出る。実機で書き換え+イラスト+抽出フォールバックを通しで確認。

---

### Phase 3: ユーザー向け文言の一元化とローカライズ ✅ 完了（実施内容は当初案から変更）
**目的**: `failureReason` 系も英語端末で英語表示にする（ログで導入済みの方式へ対称化）。

#### 実施内容（軽量版・当初の案Aから変更）
当初は案A（`AppError` + key/args へのスキーマ移行）を採用する計画だったが、実装に着手した時点で
**固定文（引数なし）のエラー文はそのまま安定した一意な日本語文字列である**ことに気づき、
それを直接 `Localizable.xcstrings` のキーとして登録し、表示側で `LocalizedStringKey` に通すだけで
同じ実用上のゴール（英語端末で英語表示）に達成できると判明したため、こちらを採用した。

- スキーマ変更なし（`failureReason`/`imageFailureReason` は `String?` のまま）
- 各サービスの `LocalizedError` 実装はコード変更なし（既存の日本語確定文をそのまま使う）
- `HistoryView`: `Text("失敗: ") + Text(LocalizedStringKey(reason))` のように 2 つの `Text` を連結し、
  ラベルと理由をそれぞれ独立してローカライズ解決
- `ReaderView`: イラスト失敗理由の `Text(reason)` を `Text(LocalizedStringKey(reason))` に変更
- HTTP ステータスコードや Gemini の生エラーメッセージなど**動的な引数を含む文言は非対象**
  （一致するキーが無ければ `LocalizedStringKey` は元の文字列にフォールバックするだけで実害はない。
  日本語のまま表示され続けるのみ）

**当初案Aとの差分**: 「grep -rln '[ぁ-ん]' LearnLanguage/Services が 0 件」という完了条件は
Services 内のコード自体は変更していないため達成していない（意図的）。実質的なゴール
（英語端末で固定エラー文が英語表示される）は達成し、`en.lproj/Localizable.strings` への
コンパイル結果で確認済み。Mock の日本語整理は Phase 1 で `MockServices.swift` 自体を
削除済みのため対象消滅。

**案Aが必要になる未来**: エラーに構造化データ（HTTP ステータスコード等）を UI で使い分けたい
（例: 401 のときだけ「設定を開く」ボタンを出す）場合は、今回の文字列ベースの方式では対応できない
→ その時初めて `AppError` + key/args ヘの本格移行（元の案A）に切り替える。

**完了条件**: 固定エラー文言が en.lproj にコンパイルされている（確認済み）。
**リスク**: 低（表示層のみの変更、スキーマ・サービスロジック共に無変更）。

---

### Phase 4: 抽出パイプラインの分解 ✅ 完了（実機ネットワーク確認は未実施）
**目的**: 421行の `ArticleContentExtractor` を「戦略の連鎖」として再構成し、Extraction 層から Generation 層（GeminiModel/Keychain）への依存を断つ。

構成（1 struct → 1ディレクトリ）:
```
Services/Extraction/
  ArticleContentExtractor.swift   // 連鎖の編成のみ（~60行）
  HTMLContentParser.swift         // extractText/extractMainContent/extractTitle/extractLang/looksBlocked（純関数・既存テストの対象）
  DirectFetcher.swift             // 素の URLSession 取得
  WebViewRenderer.swift           // WKWebView 描画（@MainActor・withTimeout ごと）
  GeminiURLContextFetcher.swift   // GeminiClient 利用（Phase 2 成果物に依存）
  JinaReaderFetcher.swift         // r.jina.ai + parseReaderResponse/cleanMarkdown
```
- 各 Fetcher は `func fetch(url:) async throws -> ExtractedArticle` の同型に揃え、`ArticleContentExtractor.extract` は閾値判定（1500字/100字）と順序（direct→webView→gemini→jina）だけを持つ
- `GeminiURLContextFetcher` はモデル名を**引数で受ける**（`GeminiModel.current` の参照は編成側=Extractor に置き、Extraction の内側から設定への依存を消す）
- static 関数の応急テスト構造を解消: `HTMLContentParser` は素直な値型に。**既存 ExtractionTests は名前空間の付け替えのみで全件維持**（テストを仕様として使う）

**完了条件**: 全テスト green（ExtractionTests 無改変が理想、リネームのみ許容）。実機で「直接取得で取れるサイト」「JS 描画サイト」「ブロックされるサイト」の3種を確認。
**リスク**: 中。WebView まわりは実機挙動が全て。フェーズを跨いで放置しない（1セッションで完了させる）。

---

### Phase 5: GenerationQueue の分割 ✅ 完了
**目的**: 282行の god object を「キュー制御」「バッチ処理」「記録」に分離し、Phase 0 のテストを維持したまま内部を差し替える。

```
Pipeline/
  GenerationQueue.swift      // @Observable。enqueue/resume/retry と直列ループのみ（~80行）
  BatchProcessor.swift       // Phase0〜2 の実処理。ports を init で受け取る（テスト対象の中心）
  ArticleLogger.swift        // log(key:args:) と ArticleLogEntry 生成
  QueueStore.swift           // FetchDescriptor 系（nextQueuedBatch/currentMinSortIndex/requeue）と status 文字列定数の一元化
```
- **`#Predicate` のマジック文字列**は `QueueStore` 内の `static let queuedRaw = ArticleStatus.queued.rawValue` 等に集約（#Predicate の制約上、式内に変数キャプチャで注入）
- Phase 0 で導入した DI をそのまま `BatchProcessor` の init に移す
- **Phase 0 のテストは1行も変えずに green を維持する**（これがこのフェーズの合否判定）

**破綻する未来**: 「並列バッチ処理（複数記事同時）」へ進化させる場合、直列前提の `isProcessing` フラグ設計が崩れる → その時は BatchProcessor を actor 化する。今回はスコープ外。

**完了条件**: Phase 0 テスト無改変 green。GenerationQueue 本体 ~80行。
**リスク**: 中。@MainActor / SwiftData の modelContext 共有に注意（全コンポーネント @MainActor のまま分割し、並行化はしない）。

---

### Phase 6: UI 層の整理 ✅ 完了（実機での見た目/挙動確認は未実施）
**目的**: 巨大 View の分割と、散在するローカライズ呼び出しパターンの集約。挙動変更なし。

- `ReaderView.swift`（304行）→ `Reader/` 配下に分割: `ReaderView` / `SegmentPageView` / `IllustrationView` / `PlaybackControls` / `TranslationSection`（+翻訳ロジックを `TranslationController`(@Observable) へ）
- `HistoryView.swift` → `HistoryRow` を別ファイルへ
- `ReadingLevel.localizedDisplayName` / `localizedShortName`（`String(localized:)` ラッパ）を追加し、View 側の `Text(LocalizedStringKey(level.displayName))` パターンを置換。ShareViewController の同型コードも置換
- `SettingsView` のセクションを小 View に分割（任意・時間があれば）
- `SampleData` は #Preview 専用であることをコメントで明示（削除しない: Preview は開発資産）

**完了条件**: ビルド green・見た目/挙動の差分ゼロ（縦横レイアウト・ドット余白・再作成ボタン等を実機確認）。1ファイル200行以下を目安。
**リスク**: 低〜中（機械的な移動が中心）。

---

### Phase 7: データモデルの整地（唯一スキーマを触るフェーズ） ✅ 完了（実機マイグレーション確認は未実施・開発中のためユーザー許諾済み）
**目的**: モデルの澱みを一掃する。**このフェーズのみ履歴データに触れるため、単独コミット+実機マイグレーション確認を必須とする。**

- `GlossaryTerm.lemma` 削除（書き込みゼロ確認済み）
- `LearningArticle.translationLanguageCode` は**リネームせず**、doc コメントを実態（「作成時の母語=用語集の訳語言語。表示翻訳は設定に追従」）に更新
  - リネーム（`glossaryLanguageCode` 等）は SwiftData の属性リネームがマイグレーション地雷のため見送り。**名前より嘘のないドキュメントを優先**
- Phase 3 で残した旧 `failureReason` 読み取り互換の削除（1リリース経過後）
- `ArticleStatus` / `SegmentImageState` の不要な `Codable` 適合を削除（SwiftData は rawValue 文字列で保存しており未使用）
- 実機手順: 旧ビルドでデータ作成 → 新ビルド上書きインストール → 履歴・画像・ログが残ることを確認（`makeModelContainer` のストア再作成フォールバックが発動しないこと）

**完了条件**: 実機で既存データ無損失。全テスト green。
**リスク**: **高**（唯一のデータ損失リスク）。だからこそ最後尾・単独で実施。

---

### Phase 8: 仕上げと再発防止 ✅ 完了（SWIFT_VERSION 更新・firstURL テスト化は見送り、理由は下記コミット参照）
- `docs/ARCHITECTURE.md` 新設: レイヤ図・依存方向（Features → Pipeline → Services → Shared、逆流禁止）・「ユーザー向け文言は必ず key+args」等の規範を1ページで明文化
- プロジェクト直下 `CLAUDE.md` に上記規範への参照とビルド/テストコマンドを記載（AI 支援開発の再発防止装置として）
- 未使用シンボルの最終スイープ（`periphery` 導入は任意。無ければ grep ベースの手動確認で可）
- `project.yml`: `SWIFT_VERSION` を環境実態（6.4）へ更新するか検討（ビルド確認の上）
- テストターゲットへの `ShareViewController.firstURL` 等の追加（Extension ロジックの回帰防止・任意）

---

## 3. 実施順序とマイルストーン

```
Phase 0 (安全網)      ██        テスト+DI最小変更
Phase 1 (削除)        █         -150行
Phase 2 (Gemini統一)  ███       -100行/挙動一貫化
Phase 3 (文言一元化)  ███       スキーマ追加(軽量)
Phase 4 (抽出分解)    ███       構造改善の山場①
Phase 5 (Queue分割)   ███       構造改善の山場②
Phase 6 (UI整理)      ██        機械的分割
Phase 7 (モデル整地)  ██        唯一のスキーマ削除・最後尾
Phase 8 (仕上げ)      █         文書化・再発防止
```

- **依存関係**: 0→1→2 は直列必須。3 は 2 の後（AppError が GeminiClient のエラーを包むため）。4 は 2 の後（GeminiURLContextFetcher が GeminiClient を使うため）。5 は 0 の後ならいつでも。6 は独立。7 は 3 の後。8 は最後
- **中断可能点**: すべてのフェーズ境界。特に 0〜3 完了時点で「動作は同じだが将来の変更コストが激減した」状態になるため、ここを第一目標とする
- 期待効果（完了時）: 総行数 約3,800→約3,300行（テストは増加）、最大ファイル 421→200行以下、Gemini 呼び出し実装 3→1、Services 層の日本語 0、心臓部（Queue/Batch）のテストカバレッジ 0→主要経路網羅

## 4. やらないこと（non-goals）
- アーキテクチャフレームワーク（TCA 等）や DI コンテナの導入 — 規模に対し過剰
- XCTest → Swift Testing への移行 — 価値に対し工数が見合わない（新規テストから任意採用は可）
- 外部 SPM 依存の追加 — 既存方針（依存ゼロ）を維持
- 機能追加・UI 刷新 — リファクタリングと混ぜない
