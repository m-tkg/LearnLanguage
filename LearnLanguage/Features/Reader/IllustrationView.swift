import SwiftUI

/// セグメントのイラスト。生成済みなら画像、生成中はスピナー、未完/失敗はプレースホルダ。
struct IllustrationView: View {
    let segment: ArticleSegment

    var body: some View {
        if let data = segment.imageData, let image = Image(data: data) {
            // 縦横比を保ったまま枠内に収める（横向きなど枠が横長でも歪ませない）。
            image
                .resizable()
                .scaledToFit()
        } else if segment.imageState == .generating || segment.imageState == .pending {
            ProgressView("イラストを生成中…")
        } else {
            ContentUnavailableView {
                Label(placeholderTitle, systemImage: placeholderSymbol)
            } description: {
                if segment.imageState == .failed, let reason = segment.imageFailureReason {
                    Text(LocalizedStringKey(reason))
                }
            }
        }
    }

    private var placeholderTitle: String {
        switch segment.imageState {
        case .generating: return "イラストを生成中…"
        case .failed: return "イラストを生成できませんでした"
        default: return "イラストはありません"
        }
    }

    private var placeholderSymbol: String {
        segment.imageState == .failed ? "photo.badge.exclamationmark" : "photo"
    }
}
