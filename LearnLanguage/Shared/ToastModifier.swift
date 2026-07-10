import SwiftUI

/// 画面下部に短時間だけ表示して自動で消えるトースト。
/// 保存完了などの軽いフィードバックに使う（`isPresented` を true にすると表示され、自動で false に戻る）。
struct ToastModifier: ViewModifier {
    @Binding var isPresented: Bool
    let message: LocalizedStringKey

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isPresented {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4, y: 2)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation { isPresented = false }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPresented)
    }
}

extension View {
    /// 下部トースト。`isPresented` が true になると表示し、1.5 秒後に自動で消える。
    func toast(_ message: LocalizedStringKey, isPresented: Binding<Bool>) -> some View {
        modifier(ToastModifier(isPresented: isPresented, message: message))
    }
}
