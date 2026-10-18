import Testing
import Foundation
import SwiftUI
@testable import Smile

@Suite("iOSNoteEditorModel formatting")
struct iOSNoteEditorModelFormattingTests {
    private let a = UUID()
    private let b = UUID()
    private let photo = DraftAttachment(persistedID: nil, kind: .photo, relativePath: "p.jpg",
                                        transcript: nil, durationSeconds: nil)

    private func makeModel() -> iOSNoteEditorModel {
        let model = iOSNoteEditorModel()
        model.segments = [
            .text(id: a, content: "嗯标题\n那个正文一", alignment: .leading),
            .photo(photo),
            .text(id: b, content: "正文二", alignment: .center),
        ]
        model.isDirty = false
        return model
    }

    @Test func snapshotSplitsTitleAndSegments() throws {
        let snap = try #require(makeModel().formattingSnapshot())
        #expect(snap.input == FormattingInput(title: "嗯标题", segments: ["那个正文一", "正文二"]))
        #expect(snap.textSegmentIDs == [a, b])
        #expect(snap.layout == [.text(0), .photo, .text(1)])
    }

    @Test func snapshotRecordsCenteredSegments() throws {
        let snap = try #require(makeModel().formattingSnapshot())
        #expect(snap.centered == [false, true])
    }

    @Test func centeredSegmentsLoseIndentButKeepBlankLines() throws {
        let snap = try #require(makeModel().formattingSnapshot())
        let result = FormattingResult(title: "标题", segments: [
            "\u{3000}\u{3000}正文一。\n\n\u{3000}\u{3000}第二段。",
            "\u{3000}\u{3000}居中一。\n\n\u{3000}\u{3000}居中二。",
        ])
        let adjusted = snap.adjustingIndent(result)
        #expect(adjusted.title == "标题")
        #expect(adjusted.segments[0] == result.segments[0])
        #expect(adjusted.segments[1] == "居中一。\n\n居中二。")
    }

    @Test func snapshotNilWithoutText() {
        let model = iOSNoteEditorModel()
        model.segments = [.photo(photo)]
        #expect(model.formattingSnapshot() == nil)
        #expect(!model.canFormat)
    }

    @Test func canFormatRequiresNonBlankText() {
        let model = iOSNoteEditorModel()
        model.segments = [.text(id: a, content: "  \n  ", alignment: .leading)]
        #expect(!model.canFormat)
        model.segments = [.text(id: a, content: "有字", alignment: .leading)]
        #expect(model.canFormat)
    }

    @Test func applyKeepsPhotoAndAlignment() throws {
        let model = makeModel()
        let snap = try #require(model.formattingSnapshot())
        let ok = model.applyFormatting(FormattingResult(title: "标题", segments: ["正文一。", "正文二。"]), to: snap)
        #expect(ok)
        #expect(model.isDirty)
        #expect(model.textContent(for: a) == "标题\n正文一。")
        #expect(model.segments[1].id == photo.id)
        guard case .text(let id, let content, let alignment) = model.segments[2] else {
            Issue.record("第三段应为文字"); return
        }
        #expect(id == b)
        #expect(content == "正文二。")
        #expect(alignment == .center)
    }

    @Test func applyWithEmptyFirstBodyHasNoTrailingNewline() throws {
        let model = iOSNoteEditorModel()
        model.segments = [.text(id: a, content: "嗯标题", alignment: .leading)]
        let snap = try #require(model.formattingSnapshot())
        #expect(snap.input == FormattingInput(title: "嗯标题", segments: [""]))
        #expect(model.applyFormatting(FormattingResult(title: "标题", segments: [""]), to: snap))
        #expect(model.textContent(for: a) == "标题")
    }

    @Test func applyReplacesNewlinesInTitle() throws {
        let model = makeModel()
        let snap = try #require(model.formattingSnapshot())
        model.applyFormatting(FormattingResult(title: "第一行\n第二行", segments: ["x", "y"]), to: snap)
        #expect(model.textContent(for: a) == "第一行 第二行\nx")
    }

    @Test func applyRejectsMismatchedCount() throws {
        let model = makeModel()
        let snap = try #require(model.formattingSnapshot())
        #expect(!model.applyFormatting(FormattingResult(title: "T", segments: ["x"]), to: snap))
        #expect(model.textContent(for: a) == "嗯标题\n那个正文一")
        #expect(!model.isDirty)
    }

    @Test func applyReplacesCRLFAndLineSeparatorInTitle() throws {
        let model = makeModel()
        let snap = try #require(model.formattingSnapshot())
        model.applyFormatting(FormattingResult(title: "甲\r\n乙\u{2028}丙", segments: ["x", "y"]), to: snap)
        #expect(model.textContent(for: a) == "甲 乙 丙\nx")
    }

    @Test func emptyTitleLineGetsGeneratedTitle() throws {
        let model = iOSNoteEditorModel()
        model.segments = [.text(id: a, content: "\n正文", alignment: .leading)]
        let snap = try #require(model.formattingSnapshot())
        #expect(snap.input == FormattingInput(title: "", segments: ["正文"]))
        #expect(model.applyFormatting(FormattingResult(title: "生成标题", segments: ["正文。"]), to: snap))
        #expect(model.textContent(for: a) == "生成标题\n正文。")
    }

    @Test func emptyGeneratedTitleKeepsLeadingNewline() throws {
        let model = iOSNoteEditorModel()
        model.segments = [.text(id: a, content: "\n正文", alignment: .leading)]
        let snap = try #require(model.formattingSnapshot())
        #expect(model.applyFormatting(FormattingResult(title: "", segments: ["正文。"]), to: snap))
        #expect(model.textContent(for: a) == "\n正文。")
    }

    @Test func applyRejectsChangedContent() throws {
        let model = makeModel()
        let snap = try #require(model.formattingSnapshot())
        model.updateText("正文二改", for: b)
        #expect(!model.applyFormatting(FormattingResult(title: "T", segments: ["x", "y"]), to: snap))
        #expect(model.textContent(for: a) == "嗯标题\n那个正文一")
        #expect(model.textContent(for: b) == "正文二改")
    }

    @Test func applyRejectsMissingSegment() throws {
        let model = makeModel()
        let snap = try #require(model.formattingSnapshot())
        model.segments.removeLast()
        #expect(!model.applyFormatting(FormattingResult(title: "T", segments: ["x", "y"]), to: snap))
        #expect(model.textContent(for: a) == "嗯标题\n那个正文一")
    }
}
