import Testing
import SwiftUI
import SnapshotTesting
@testable import Smile

@Suite("Snapshot", .serialized)
@MainActor
struct SnapshotTests {

    @Test func emptyJarCard() {
        let group = Group(name: "微笑储蓄罐", iconSymbol: "face.smiling",
                          colorHex: "#E08A4A", isBuiltIn: true)
        let view = JarCardView(group: group, recentEntry: nil, isLocked: false, onTap: {})
            .frame(width: 360)
            .padding()
            .background(AppColors.backgroundGradient)

        assertSnapshot(of: UIHostingController(rootView: view),
                       as: .image(on: .iPhone13))
    }

    @Test func customGroupJarCard() {
        let group = Group(name: "家人", iconSymbol: "heart",
                          colorHex: "#7AA350", isBuiltIn: false)
        let view = JarCardView(group: group, recentEntry: nil, isLocked: false, onTap: {})
            .frame(width: 360)
            .padding()
            .background(AppColors.backgroundGradient)

        assertSnapshot(of: UIHostingController(rootView: view),
                       as: .image(on: .iPhone13))
    }

    @Test func noteEditorTitleStyle() {
        let view = VStack(spacing: 0) {
            NoteTextView(segmentID: UUID(), text: "周末去爬山\n山顶的风很大，大家一起拍了合照。\n下山路上还看到了松鼠。",
                         hasTitle: true, alignment: .leading, minHeight: 72,
                         focusedSegmentID: .constant(nil), onChange: { _ in })
            NoteTextView(segmentID: UUID(), text: "照片后面的另一段正文，第一行不是标题。",
                         hasTitle: false, alignment: .leading, minHeight: 72,
                         focusedSegmentID: .constant(nil), onChange: { _ in })
        }
        .padding(.horizontal, 21)
        .frame(width: 390)
        .background(AppColors.backgroundGradient)

        assertSnapshot(of: UIHostingController(rootView: view), as: .image(on: .iPhone13))
    }

    @Test(arguments: ArticleStyle.allCases)
    func articleTextBlock(style: ArticleStyle) {
        let view = VStack(spacing: 24) {
            ArticleTextBlock(text: "　　山顶的风很大，大家一起拍了合照。阳光很好，远处的云一层一层铺开，像是谁把棉花摊在了天边。\n\n　　下山路上还看到了松鼠。", centered: false, style: style)
            ArticleTextBlock(text: "居中的一句话\n第二行", centered: true, style: style)
        }
        .padding(.horizontal, style.metrics.horizontalMargin)
        .frame(width: 390)
        .background(style.background)

        assertSnapshot(of: UIHostingController(rootView: view), as: .image(on: .iPhone13), named: style.rawValue)
    }

    @Test func shareCardSnapshot() {
        let data = ShareCardRenderer.CardData(
            groupName: "微笑储蓄罐", dateText: "5月23日",
            title: "咖啡店的老板记得我",
            bodySnippet: "今天去常去的那家店,老板抬头就笑着说……",
            primaryImage: nil
        )
        let image = ShareCardRenderer.render(data)!
        assertSnapshot(of: image, as: .image)
    }
}
