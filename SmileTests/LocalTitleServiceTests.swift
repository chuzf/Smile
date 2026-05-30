import Testing
import Foundation
@testable import Smile

@Suite("LocalTitleService")
struct LocalTitleServiceTests {
    let svc = LocalTitleService()

    @Test func usesFirstSentenceFromBody() async throws {
        let ctx = TitleContext(groupName: "微笑储蓄罐",
                               date: Date(timeIntervalSince1970: 0),
                               hasMedia: false)
        let t = try await svc.generateTitle(text: "今天遇到老朋友。聊了很久。", context: ctx)
        #expect(t == "今天遇到老朋友")
    }

    @Test func truncatesToTwentyChars() async throws {
        let ctx = TitleContext(groupName: "微笑储蓄罐", date: Date(), hasMedia: false)
        let long = String(repeating: "甲", count: 50)
        let t = try await svc.generateTitle(text: long, context: ctx)
        #expect(t.count == 20)
    }

    @Test func fallsBackToDateGroup() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.date(from: "2026-05-23")!
        let ctx = TitleContext(groupName: "优势储蓄罐", date: date, hasMedia: true)
        let t = try await svc.generateTitle(text: "", context: ctx)
        #expect(t == "5月23日 · 优势储蓄罐")
    }
}
