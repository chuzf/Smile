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
