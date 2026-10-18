import Testing
import Foundation
@testable import Smile

@Suite("ArticleStyle")
struct ArticleStyleTests {
    @Test func defaultIsWechat() {
        #expect(ArticleStyle.default == .wechat)
        #expect(ArticleStyle(rawValue: "unknown") == nil)
    }

    @Test func wechatMetrics() {
        let m = ArticleStyle.wechat.metrics
        #expect(m.horizontalMargin == 24)
        #expect(m.fontSize == 17)
        #expect(m.lineHeight == 30)
        #expect(m.kern == 0.3)
        #expect(m.firstLineIndent == 0)
        #expect(m.paragraphSpacing == 20)
        #expect(m.photoCornerRadius == 4)
    }

    @Test func bookMetrics() {
        let m = ArticleStyle.book.metrics
        #expect(m.horizontalMargin == 28)
        #expect(m.fontSize == 17)
        #expect(m.lineHeight == 31)
        #expect(m.kern == 0.3)
        #expect(m.firstLineIndent == 34)
        #expect(m.paragraphSpacing == 10)
        #expect(m.photoCornerRadius == 8)
    }

    @Test func splitsOnEveryLineAndStripsIndent() {
        let text = "\u{3000}\u{3000}第一段。\n\n\u{3000}\u{3000}第二段。\n第三段。"
        #expect(ArticleStyle.paragraphs(from: text) == ["第一段。", "第二段。", "第三段。"])
    }

    @Test func stripsMixedWhitespaceAndCRLF() {
        let text = "  甲  \r\n\t乙\u{3000}\r\n\r\n\n \u{3000} \n丙"
        #expect(ArticleStyle.paragraphs(from: text) == ["甲", "乙", "丙"])
    }

    @Test func emptyAndBlankTextHaveNoParagraphs() {
        #expect(ArticleStyle.paragraphs(from: "").isEmpty)
        #expect(ArticleStyle.paragraphs(from: " \n\u{3000}\n\t").isEmpty)
    }

    @Test func keepsInnerSpaces() {
        #expect(ArticleStyle.paragraphs(from: "Hello world 你好") == ["Hello world 你好"])
    }
}
