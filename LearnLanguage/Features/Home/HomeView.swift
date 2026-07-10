import SwiftUI

/// URL 入力・レベル選択・生成トリガの画面。生成はキューに追加し、すぐ次を入力できる。
struct HomeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GenerationQueue.self) private var queue
    @AppStorage("nativeLanguageCode") private var nativeLanguageCode = "ja"
    /// 設定のデフォルトレベル（作成画面の初期値に使うだけ。ここでの変更はデフォルトに影響させない）。
    @AppStorage("defaultReadingLevel") private var defaultLevel: ReadingLevel = .beginner
    /// 設定のデフォルト学習対象言語（同上）。
    @AppStorage("targetLanguageCode") private var defaultTargetLanguage = "en"
    /// この作成画面で選択中のレベル（デフォルトを初期値にするが独立して扱う）。
    @State private var level: ReadingLevel = .beginner
    /// この作成画面で選択中の学習対象言語（デフォルトを初期値にするが独立して扱う）。
    @State private var targetLanguage = "en"
    @State private var model = HomeViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("記事") {
                    TextField("記事の URL", text: $model.urlString)
                        .textContentType(.URL)
                        .urlKeyboard()
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("学習対象言語", selection: $targetLanguage) {
                        ForEach(LanguageOptions.all, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    Picker("レベル", selection: $level) {
                        ForEach(ReadingLevel.allCases) { level in
                            Text(LocalizedStringKey(level.displayName)).tag(level)
                        }
                    }
                } header: {
                    Text("レベル")
                } footer: {
                    Text("元記事が別の言語でも、学習対象言語に翻訳して教材化します。")
                }

                Section {
                    Button {
                        guard let url = model.validatedURL() else { return }
                        queue.enqueue(url: url, level: level,
                                      targetLanguageCode: targetLanguage,
                                      nativeLanguageCode: nativeLanguageCode)
                        model.reset()
                        dismiss()
                    } label: {
                        Text("教材を作成")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canCreate)
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("記事を追加")
            .inlineNavigationBarTitle()
            .onAppear {
                level = defaultLevel
                targetLanguage = defaultTargetLanguage
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }
}
