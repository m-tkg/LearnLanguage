import SwiftUI

/// 記事一覧の 1 行。
struct HistoryRow: View {
    let article: LearningArticle

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.headline)
                    .lineLimit(2)
                statusOrMeta
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if article.isFavorite {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            let sorted = article.segments.sorted { $0.order < $1.order }
            if let data = sorted.first(where: { $0.imageData != nil })?.imageData,
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            }
            // 本文取得前だけ全面スピナー。イラスト生成中（本文あり）は隠さず表示する。
            if article.status == .queued || (article.status == .processing && article.segments.isEmpty) {
                RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial)
                ProgressView()
            } else if article.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if article.segments.isEmpty {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusOrMeta: some View {
        switch article.status {
        case .queued:
            Text("待機中…")
        case .processing:
            Text(article.segments.isEmpty ? LocalizedStringKey("本文を取得中…") : LocalizedStringKey("イラストを生成中…"))
        case .failed:
            // ラベル（"失敗: %@"）と理由をそれぞれ独立にローカライズ解決する
            // （Text の補間に Text を埋め込む。理由が動的な引数を含む文言の場合は
            //   キーが一致せず日本語のまま表示される）。
            Text("失敗: \(Text(LocalizedStringKey(article.failureReason ?? "不明なエラー")))")
                .foregroundStyle(.red)
        case .completed:
            HStack(spacing: 8) {
                Text(LocalizedStringKey(ReadingLevel(storageValue: article.targetLevel, isOriginal: article.isOriginal).shortName))
                Text(article.sourceURL.host() ?? article.sourceURL.absoluteString)
                    .lineLimit(1)
            }
        }
    }
}
