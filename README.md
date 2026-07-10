# LearnLanguage

記事 URL を渡すと、AI が語彙レベルに合わせて本文を書き換え、内容を説明するイラストを付けた
語学教材を自動生成する iOS/iPadOS アプリ。読み上げ・母語訳・用語集付きで、生成した教材は
端末内に蓄積される。まずは英語学習向け（将来多言語対応を見据えた設計）。

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

## セットアップ

```sh
brew install xcodegen   # 未導入の場合
xcodegen generate       # project.yml から .xcodeproj を生成（.xcodeproj はコミットしない）
open LearnLanguage.xcodeproj
```

署名（DEVELOPMENT_TEAM）は `project.yml` に設定済み。Share Extension を実機で使うには
App Group `group.com.mtkg.LearnLanguage` の provisioning が必要（Xcode が自動処理）。

### API キー（BYOK・すべて端末の Keychain にのみ保存）

| 用途 | プロバイダ | 備考 |
|---|---|---|
| 本文の書き換え | Gemini（既定）または オンデバイス | Gemini はテキスト無料枠あり。[Google AI Studio](https://aistudio.google.com/apikey) でキー取得 |
| イラスト生成 | Pollinations（既定・キー不要）/ Cloudflare Workers AI / Gemini | Cloudflare は無料枠が広く安定（Account ID + Workers AI 権限の API トークン）。Gemini 画像は実質有料 |

すべてアプリ内の設定画面から入力する。

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
