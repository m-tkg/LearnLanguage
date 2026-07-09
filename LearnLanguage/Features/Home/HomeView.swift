import SwiftUI

/// URL 入力・レベル選択・生成トリガの画面。生成はキューに追加し、すぐ次を入力できる。
struct HomeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GenerationQueue.self) private var queue
    @AppStorage("nativeLanguageCode") private var nativeLanguageCode = "ja"
    /// 設定のデフォルトレベル（作成画面の初期値に使うだけ。ここでの変更はデフォルトに影響させない）。
    @AppStorage("defaultReadingLevel") private var defaultLevel: ReadingLevel = .beginner
    /// この作成画面で選択中のレベル（デフォルトを初期値にするが独立して扱う）。
    @State private var level: ReadingLevel = .beginner
    @State private var model = HomeViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("記事") {
                    TextField("記事の URL", text: $model.urlString)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("レベル") {
                    Picker("レベル", selection: $level) {
                        ForEach(ReadingLevel.allCases) { level in
                            Text(LocalizedStringKey(level.displayName)).tag(level)
                        }
                    }
                }

                Section {
                    Button {
                        guard let url = model.validatedURL() else { return }
                        queue.enqueue(url: url, level: level, nativeLanguageCode: nativeLanguageCode)
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
            .navigationTitle("記事を追加")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { level = defaultLevel }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }
}
