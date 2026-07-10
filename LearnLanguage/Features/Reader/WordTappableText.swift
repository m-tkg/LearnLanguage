import SwiftUI

/// 本文を単語単位で描画し、単語の長押しでコールバックする本文ビュー。
/// 用語集（レベル超過語）に含まれる単語は従来どおり太字で強調する。
/// `Text(AttributedString)` では単語単位のジェスチャが取れないため、
/// `WordTokenizer` で分解した run を折り返しレイアウト（`FlowLayout`）で並べる。
struct WordTappableText: View {
    let text: String
    let glossarySurfaces: [String]
    let onWordLongPress: (String) -> Void

    /// 用語集 surface を構成する単語の集合（複数語の surface は単語に分解して照合する）。
    private var emphasizedWords: Set<String> {
        Set(glossarySurfaces.flatMap { surface in
            surface.lowercased().split(separator: " ").map(String.init)
        })
    }

    var body: some View {
        let emphasized = emphasizedWords
        FlowLayout(lineSpacing: 6) {
            ForEach(WordTokenizer.runs(for: text)) { run in
                if run.isWord {
                    Text(run.text)
                        .fontWeight(emphasized.contains(run.text.lowercased()) ? .bold : .regular)
                        .onLongPressGesture(minimumDuration: 0.4) {
                            onWordLongPress(run.text)
                        }
                } else {
                    Text(run.text)
                }
            }
        }
    }
}

/// 子ビューを左から右へ並べ、幅を超えたら折り返す単純なフローレイアウト。
struct FlowLayout: Layout {
    var lineSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        return arrange(subviews: subviews, maxWidth: maxWidth).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews: subviews, maxWidth: bounds.width)
        for (index, origin) in arrangement.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                // 折り返し。
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, x)
        }
        return (origins, CGSize(width: totalWidth, height: y + lineHeight))
    }
}
