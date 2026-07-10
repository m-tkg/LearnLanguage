import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// iOS / macOS のマルチプラットフォーム差分をここに集約する。
/// iOS 専用の SwiftUI modifier は macOS では no-op にし、呼び出し側の `#if` 分岐を減らす。

extension Image {
    /// エンコード済み画像データ（HEIC/PNG 等）から生成する。デコードできなければ nil。
    init?(data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #else
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #endif
    }
}

extension View {
    /// ナビゲーションタイトルをインライン表示にする（macOS では常にタイトルバー表示のため no-op）。
    @ViewBuilder
    func inlineNavigationBarTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// URL・API キーなどの入力欄向け: 自動大文字化を無効にする（macOS には概念がなく no-op）。
    @ViewBuilder
    func noAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// URL 入力欄向けのソフトウェアキーボード指定（macOS は物理キーボードのため no-op）。
    @ViewBuilder
    func urlKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.URL)
        #else
        self
        #endif
    }

    /// 単語の意味シートなどの「低い」シート表示（macOS のシートは detent 非対応のため no-op）。
    @ViewBuilder
    func compactSheetPresentation() -> some View {
        #if os(iOS)
        presentationDetents([.height(200)])
            .presentationDragIndicator(.visible)
        #else
        self
        #endif
    }
}
