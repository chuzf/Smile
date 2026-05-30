import Testing
import UIKit
@testable import Smile

@Suite("ShareCardRenderer", .serialized)
@MainActor
struct ShareCardRendererTests {
    @Test func rendersSuccessfully() {
        let data = ShareCardRenderer.CardData(
            groupName: "微笑储蓄罐",
            dateText: "5月23日",
            title: "咖啡店的老板记得我",
            bodySnippet: "今天去常去的那家店,老板抬头就笑着说……",
            primaryImage: nil
        )
        let image = ShareCardRenderer.render(data)
        #expect(image != nil)
        #expect(image!.size.width >= 1000)
    }
}
