# クリーンアップ計画（2026-07 実測ベース）

## 経緯と前提

「蓄積した無駄を全面リファクタリングしたい」という要望に対し、まず実測した。

- 総規模 5,504 行（テスト込み）。最大のプロダクションファイルは `Persistence/Models.swift` の 220 行。
- TODO / FIXME / HACK / 暫定マーカー: **0 件**。
- 直近に 9 フェーズの全面リファクタリング（`REFACTORING_PLAN.md`）を完了済みで、
  レイヤ規範（`ARCHITECTURE.md`）と現行コードは一致している。99 テスト green・警告ゼロ。

**結論: 全面リファクタリングは不要**。構造の再編・書き直しはやらない。
代わりに、実測で確認できた残課題だけを対象に、小さく安全な順で片付ける。
各フェーズは独立して価値があり、途中でやめても壊れない。

## やらないこと（明示）

- レイヤ構成・ファイル分割の再編（直近のリファクタで確定済み。`ARCHITECTURE.md` が正）。
- `GeminiClient` と `IllustratorRetry` のリトライ統合。形が違うのは意図的
  （Gemini は throwing + retryAfter + PerDay 即失敗、イラストは Result + 固定バックオフ）で、
  統合すると両方の要件を汎用化した複雑な仕組みになる。二重実装のままが最もシンプル。
- `Persistence/Models.swift` の optional store（`segmentsStore` 等）+ computed ラッパの解消。
  ボイラープレートに見えるが CloudKit スキーマ要件（リレーション optional 必須）由来の必要コード。

---

## Phase 1: 互換レイヤ・死蔵データの削除（低リスク・半日）

開発中でデータ損失を許容する方針（ユーザー確認済み）を根拠に、移行・互換コードを削る。
**ただし全端末（iPhone / iPad）が最新ビルドに更新済みであることを確認してから着手する。**

1. `KeychainStore.migrateToSynchronizable(accounts:)` と App 起動時の呼び出しを削除
   （iCloud キーチェーン同期対応前のローカル項目の一度きり移行。全端末移行済みなら不要）。
2. `Localizable.xcstrings` の stale エントリ掃除（例: 旧キー「処理を開始しました。」）。
   ただし **SwiftData に保存済みの旧ログが旧キーを参照する**ため、削除は「全端末で記事を
   作り直してよい」時期に行うか、旧キーを残す判断を明記する。
3. `ArticleLogEntry.messageKey/messageArgs` のデフォルト値による旧スキーマ互換の要否を再判定。
4. 各削除は単独コミット。テスト（`KeychainStoreTests` 等）も対応するものを同時に削除する。

**破綻条件**: TestFlight 配布先に旧ビルドの端末が残っていると、移行コード削除でその端末の
キーが同期されなくなる。着手前に配布状況を確認すること。

## Phase 2: 概念の一本化 — 翻訳先言語（中リスク・1日）

現状、翻訳先（母語）の概念が二重になっている:

- `LearningArticle.translationLanguageCode` — enqueue 時に保存（`BatchProcessor` が用語集の訳語生成に使用）
- `@AppStorage("nativeLanguageCode")` — Reader の翻訳・単語の意味表示が使用（設定に追従）

「記事作成時の母語」と「今の母語」が食い違うと、用語集の訳語と長押し翻訳の言語がズレる。

1. 仕様を決める: **「常に現在の設定に追従」に寄せる**（Reader の実態に合わせる）。
2. `BatchProcessor` も設定値を読む形にし、`translationLanguageCode` は未使用化する。
3. **CloudKit の Production スキーマからフィールドは削除できない**（additive only）ため、
   モデルからの物理削除はしない。「未使用（deprecated）」コメントを付けて残す。
4. スキーマに触らないのでスキーマ変更コミットの分離は不要だが、挙動変更なのでテストを先に書く
   （用語集の訳語が現在の設定言語で生成されること）。

**破綻条件**: 将来「記事ごとに母語を固定したい」要件が出たら、この一本化は逆方向の変更になる。
その場合は translationLanguageCode を復活させる（フィールドは残っているので追加移行は不要）。

## Phase 3: 既知のもろさの解消（中リスク・1日）

1. **`failureReason` の言語固定問題**: 現在 `error.localizedDescription` の文字列を直接保存しており、
   保存時の言語で固定される（`HistoryRow` は xcstrings キー一致時のみ翻訳される暫定対応）。
   処理ログと同じ **key + args 方式**（`messageKey/messageArgs` 相当）に統一し、表示時に言語解決する。
   スキーマにフィールド追加が必要 → **単独コミット + リリース前に CloudKit Production デプロイ**。
2. **SwiftData の isDeleted 反転バグ**（`REFACTORING_PLAN.md` §F 記載の latent bug: delete() 後の
   save() で isDeleted が false に戻る）: 現在は fetch レベルの保証で回避済み。`BatchProcessor` 内の
   `article.isDeleted` チェックが将来の SwiftData 更新で誤動作しないか、削除競合の統合テストを追加して
   検知可能にする（挙動変更はしない）。

## Phase 4: 開発体験の整備（低リスク・半日）

1. `Localizable.xcstrings` の JSON 妥当性チェックをコミット前に自動化
   （Xcode が頻繁に並べ替える + 手編集で壊しやすいため。`python3 -c "json.load(...)"` を
   pre-commit か CI の軽量チェックに）。
2. README の手順（CloudKit Production デプロイ・リリース手順）と実運用の差分を棚卸し。
3. `ArticleContentExtractor` の抽出段階（直接取得 → WebView → Jina）の判断ログを整理し、
   「どの段で取れたか」を処理ログに 1 行残す（取得失敗の調査コスト削減）。

---

## 進め方の原則（全フェーズ共通）

- 1 フェーズ = 1〜数コミット。エラー・テスト失敗を残したまま次へ進まない。
- 挙動を変える変更はテスト先行（t_wada 流 TDD）。削除はテストも同時に削除。
- SwiftData スキーマ変更は他と混ぜず単独コミット + リリース前に CloudKit Production デプロイ。
- 各フェーズ完了時に `xcodebuild test`（iPhone 17 Pro Max Simulator）が green であること。
