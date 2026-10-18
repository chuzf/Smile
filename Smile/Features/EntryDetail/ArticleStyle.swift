import SwiftUI
import UIKit

/// 详情页正文排版风格；只影响显示，不改存储
enum ArticleStyle: String, CaseIterable, Identifiable {
    case wechat, book

    static let storageKey = "detail_article_style"
    static let `default`: ArticleStyle = .wechat

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wechat: return "公众号"
        case .book: return "书籍"
        }
    }

    struct Metrics: Equatable {
        /// 文字与图片共用，左右边缘对齐
        let horizontalMargin: CGFloat
        let fontSize: CGFloat
        let lineHeight: CGFloat
        let kern: CGFloat
        let firstLineIndent: CGFloat
        let paragraphSpacing: CGFloat
        let photoCornerRadius: CGFloat
    }

    var metrics: Metrics {
        switch self {
        case .wechat:
            return Metrics(horizontalMargin: 24, fontSize: 17, lineHeight: 30, kern: 0.3,
                           firstLineIndent: 0, paragraphSpacing: 20, photoCornerRadius: 4)
        case .book:
            return Metrics(horizontalMargin: 28, fontSize: 17, lineHeight: 31, kern: 0.3,
                           firstLineIndent: 34, paragraphSpacing: 10, photoCornerRadius: 8)
        }
    }

    @ViewBuilder
    var background: some View {
        switch self {
        case .wechat: Color(hex: "#FFFCF7")
        case .book: AppColors.backgroundGradient
        }
    }

    /// 正文颜色比 textPrimary 深一档，长文更易读
    static let bodyColor = UIColor(red: 0x3D / 255, green: 0x2B / 255, blue: 0x1F / 255, alpha: 1)

    /// 每个非空行是一段，去掉首尾空白（含全角空格）；缩进统一由排版参数决定，不依赖原文里的空格
    static func paragraphs(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - 正文段落

/// 一个文字段按当前风格排版：段落之间用段间距分隔；整段放在一个可选择的文本视图里，能跨段落选择复制
struct ArticleTextBlock: View {
    let text: String
    let centered: Bool
    let style: ArticleStyle

    var body: some View {
        ArticleText(paragraphs: ArticleStyle.paragraphs(from: text), metrics: style.metrics, centered: centered)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}

/// SwiftUI 的 Text 不支持两端对齐、固定行高和首行缩进，用只读的 UITextView 渲染（UILabel 不能选择复制文字）
struct ArticleText: UIViewRepresentable {
    let paragraphs: [String]
    let metrics: ArticleStyle.Metrics
    /// 居中段落不缩进、不两端对齐
    let centered: Bool

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1 与 UILabel 的固定行高效果一致；TextKit 2 下行距会偏小
        let view = UITextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let font = UIFont.systemFont(ofSize: metrics.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centered ? .center : .justified
        paragraph.minimumLineHeight = metrics.lineHeight
        paragraph.maximumLineHeight = metrics.lineHeight
        paragraph.firstLineHeadIndent = centered ? 0 : metrics.firstLineIndent
        paragraph.paragraphSpacing = metrics.paragraphSpacing
        let attributed = NSAttributedString(string: paragraphs.joined(separator: "\n"), attributes: [
            .font: font,
            .kern: metrics.kern,
            .foregroundColor: ArticleStyle.bodyColor,
            .paragraphStyle: paragraph,
            // 固定行高时字形贴着行底，上移一点让文字在行内居中
            .baselineOffset: (metrics.lineHeight - font.lineHeight) / 4,
        ])
        if view.attributedText != attributed { view.attributedText = attributed }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }
}
