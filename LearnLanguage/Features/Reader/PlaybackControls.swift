import SwiftUI

/// 読み上げの再生/停止トグルと速度スライダー。読み上げ中は「停止」ボタンになる。
struct PlaybackControls: View {
    @Binding var rate: Double
    let isSpeaking: Bool
    let onPlay: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tortoise")
            Slider(value: $rate, in: 0...1)
            Image(systemName: "hare")
            Button {
                isSpeaking ? onStop() : onPlay()
            } label: {
                Image(systemName: isSpeaking ? "stop.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .tint(isSpeaking ? .red : .accentColor)
            .accessibilityLabel(isSpeaking ? Text("停止") : Text("読み上げ"))
        }
        .padding()
        .background(.bar)
    }
}
