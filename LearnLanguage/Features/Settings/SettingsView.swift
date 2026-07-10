import SwiftUI

/// 母語・既定レベル・既定読み上げ速度の設定画面。設定は AppStorage に保存する。
struct SettingsView: View {
    @AppStorage("nativeLanguageCode") private var nativeLanguageCode = "ja"
    @AppStorage("speechRate") private var speechRate = 0.5
    @AppStorage("defaultReadingLevel") private var defaultLevel = ReadingLevel.beginner
    @AppStorage(IllustratorFactory.providerDefaultsKey) private var imageProvider = ImageProvider.pollinations.rawValue
    @AppStorage(RewriterFactory.providerDefaultsKey) private var rewriteProvider = RewriteProvider.gemini.rawValue
    @AppStorage(GeminiModel.defaultsKey) private var geminiModel = GeminiModel.flashLite.rawValue

    /// Gemini キーが書き換え・画像のどちらかで使われるか。
    private var usesGemini: Bool {
        rewriteProvider == RewriteProvider.gemini.rawValue
            || imageProvider == ImageProvider.gemini.rawValue
    }

    /// Gemini API キー（Keychain 保存）。画面上は編集用に一時保持する。
    @State private var geminiAPIKey = ""
    @State private var keySaved = false
    /// Pollinations API キー（任意）。
    @State private var pollinationsAPIKey = ""
    @State private var pollinationsKeySaved = false
    /// Cloudflare Workers AI の認証情報（Account ID + API トークン）。
    @State private var cloudflareAccountID = ""
    @State private var cloudflareAPIToken = ""
    @State private var cloudflareSaved = false
    /// 保存完了トーストの表示。
    @State private var showingSavedToast = false

    /// 母語の選択肢（多言語展開に備え、コード駆動で保持）。
    private let nativeLanguages: [(code: String, name: String)] = [
        ("ja", "日本語"),
        ("en", "English"),
        ("zh", "中文"),
        ("ko", "한국어"),
        ("es", "Español"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("学習") {
                    Picker("母語", selection: $nativeLanguageCode) {
                        ForEach(nativeLanguages, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    Picker("既定レベル", selection: $defaultLevel) {
                        ForEach(ReadingLevel.allCases) { level in
                            Text(LocalizedStringKey(level.displayName)).tag(level)
                        }
                    }
                }

                Section {
                    Picker("書き換え", selection: $rewriteProvider) {
                        ForEach(RewriteProvider.allCases) { provider in
                            Text(LocalizedStringKey(provider.displayName)).tag(provider.rawValue)
                        }
                    }
                    if rewriteProvider == RewriteProvider.gemini.rawValue {
                        Picker("モデル", selection: $geminiModel) {
                            ForEach(GeminiModel.allCases) { model in
                                Text(LocalizedStringKey(model.displayName)).tag(model.rawValue)
                            }
                        }
                    }
                } header: {
                    Text("文章の書き換え")
                } footer: {
                    Text("「Gemini」はクラウドで安定して書き換えます（テキストは無料枠あり・要 API キー）。「オンデバイス」は Apple Intelligence で端末内処理（非公開だが薄い記事で失敗しやすい）。\n\n無料枠の1日上限はモデルごとに別々です。片方が上限に達したら、別のモデルに切り替えると引き続き使えます。")
                }

                Section {
                    Picker("画像プロバイダ", selection: $imageProvider) {
                        ForEach(ImageProvider.allCases) { provider in
                            Text(LocalizedStringKey(provider.displayName)).tag(provider.rawValue)
                        }
                    }
                } header: {
                    Text("イラスト生成")
                } footer: {
                    Text("「無料（Pollinations）」はキー不要・自動生成です（混雑時に失敗することがあります）。「Cloudflare」は無料アカウント登録が必要ですが無料枠が広く安定しています。「Gemini」は無料枠では画像生成が制限される（429）ため実質有料です。")
                }

                if imageProvider == ImageProvider.pollinations.rawValue {
                    Section {
                        SecureField("Pollinations API キー（任意）", text: $pollinationsAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("保存") {
                            KeychainStore.set(pollinationsAPIKey, account: KeychainStore.pollinationsAPIKeyAccount)
                            pollinationsKeySaved = KeychainStore.exists(account: KeychainStore.pollinationsAPIKeyAccount)
                            showingSavedToast = true
                        }
                        .disabled(pollinationsAPIKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    } header: {
                        Text("Pollinations API キー（任意）")
                    } footer: {
                        Text("未設定でも使えます（匿名: 15秒に1回）。auth.pollinations.ai で無料登録してキーを入れると 5秒に1回に緩和され、失敗が減ります。キーは端末の Keychain にのみ保存されます。\(pollinationsKeySaved ? "  ✅ 設定済み" : "")")
                    }
                }

                if imageProvider == ImageProvider.cloudflare.rawValue {
                    Section {
                        TextField("Account ID", text: $cloudflareAccountID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("API トークン", text: $cloudflareAPIToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("保存") {
                            KeychainStore.set(cloudflareAccountID, account: KeychainStore.cloudflareAccountIDAccount)
                            KeychainStore.set(cloudflareAPIToken, account: KeychainStore.cloudflareAPITokenAccount)
                            cloudflareSaved = KeychainStore.exists(account: KeychainStore.cloudflareAccountIDAccount)
                                && KeychainStore.exists(account: KeychainStore.cloudflareAPITokenAccount)
                            showingSavedToast = true
                        }
                        .disabled(cloudflareAccountID.trimmingCharacters(in: .whitespaces).isEmpty
                                  || cloudflareAPIToken.trimmingCharacters(in: .whitespaces).isEmpty)
                    } header: {
                        Text("Cloudflare Workers AI")
                    } footer: {
                        Text("dash.cloudflare.com で無料アカウントを作成し、「Workers AI」の権限を付けた API トークンを発行してください。Account ID はダッシュボードの右サイドバー（または URL）に表示されます。無料枠は1日単位でリセットされます。いずれも端末の Keychain にのみ保存されます。\(cloudflareSaved ? "  ✅ 設定済み" : "")")
                    }
                }

                if usesGemini {
                    Section {
                        SecureField("Gemini API キー", text: $geminiAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("保存") {
                            KeychainStore.set(geminiAPIKey, account: KeychainStore.geminiAPIKeyAccount)
                            keySaved = KeychainStore.exists(account: KeychainStore.geminiAPIKeyAccount)
                            showingSavedToast = true
                        }
                        .disabled(geminiAPIKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    } header: {
                        Text("Gemini API キー")
                    } footer: {
                        Text("Google AI Studio で取得（無料）。文章の書き換えは無料枠で使えます。画像生成に使う場合は Google Cloud で請求（billing）の有効化が必要です。キーは端末の Keychain にのみ保存されます。\(keySaved ? "  ✅ 設定済み" : "")")
                    }
                }

                Section {
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: $speechRate, in: 0...1)
                        Image(systemName: "hare")
                    }
                } header: {
                    Text("既定の読み上げ速度")
                } footer: {
                    Text("学習画面の読み上げの初期速度です。学習画面でも変更できます。")
                }
            }
            .navigationTitle("設定")
            .toast("保存しました", isPresented: $showingSavedToast)
            .onAppear {
                geminiAPIKey = KeychainStore.get(account: KeychainStore.geminiAPIKeyAccount) ?? ""
                keySaved = !geminiAPIKey.isEmpty
                pollinationsAPIKey = KeychainStore.get(account: KeychainStore.pollinationsAPIKeyAccount) ?? ""
                pollinationsKeySaved = !pollinationsAPIKey.isEmpty
                cloudflareAccountID = KeychainStore.get(account: KeychainStore.cloudflareAccountIDAccount) ?? ""
                cloudflareAPIToken = KeychainStore.get(account: KeychainStore.cloudflareAPITokenAccount) ?? ""
                cloudflareSaved = !cloudflareAccountID.isEmpty && !cloudflareAPIToken.isEmpty
            }
        }
    }
}

#Preview {
    SettingsView()
}
