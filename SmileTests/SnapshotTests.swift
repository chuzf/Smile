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
