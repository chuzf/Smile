import Testing
import SwiftData
@testable import SmileJar

@Suite("iOS Note Editor Model")
struct iOSNoteEditorModelTests {

    // NOTE: These tests reference the old single-string API (editorText / extractTitleAndBody)
    // which was replaced by the segments-based API. Preserved for history; commented out
    // to avoid compile errors.
    //
    // @Test("Extract title and body with title only")
    // func extractTitleAndBody_withTitleOnly() {
    //     let model = iOSNoteEditorModel()
    //     model.editorText = "我的标题"
    //     let (title, body) = model.extractTitleAndBody()
    //     #expect(title == "我的标题")
    //     #expect(body == "")
    // }
    //
    // @Test("Extract title and body with title and body")
    // func extractTitleAndBody_withTitleAndBody() {
    //     let model = iOSNoteEditorModel()
    //     model.editorText = "我的标题\n这是正文"
    //     let (title, body) = model.extractTitleAndBody()
    //     #expect(title == "我的标题")
    //     #expect(body == "这是正文")
    // }
    //
    // @Test("Extract title and body with multiline body")
    // func extractTitleAndBody_withMultilineBody() {
    //     let model = iOSNoteEditorModel()
    //     model.editorText = "标题\n第一行\n第二行\n第三行"
    //     let (title, body) = model.extractTitleAndBody()
    //     #expect(title == "标题")
    //     #expect(body == "第一行\n第二行\n第三行")
    // }
    //
    // @Test("Extract title and body with empty text")
    // func extractTitleAndBody_emptyText() {
    //     let model = iOSNoteEditorModel()
    //     model.editorText = ""
    //     let (title, body) = model.extractTitleAndBody()
    //     #expect(title == "")
    //     #expect(body == "")
    // }
    //
    // @Test("Reset clears all state - old API")
    // func reset_clearsAllState_oldAPI() {
    //     let model = iOSNoteEditorModel()
    //     model.editorText = "some text"
    //     model.isDirty = true
    //     model.reset()
    //     #expect(model.editorText == "")
    //     #expect(model.isDirty == false)
    //     #expect(model.selectedGroupID == nil)
    // }

    @Test("Schedule auto save sets dirty flag")
    func scheduleAutoSave_setsDirtyFlag() {
        let model = iOSNoteEditorModel()
        model.isDirty = false
        model.scheduleAutoSave()

        #expect(model.isDirty == true)
    }

    @Test("Reset clears all state")
    func reset_clearsAllState() {
        let model = iOSNoteEditorModel()
        model.isDirty = true

        model.reset()

        #expect(model.isDirty == false)
        #expect(model.selectedGroupID == nil)
        // segments resets to a single empty text segment
        #expect(model.segments.count == 1)
    }

    @Test("updateAlignment changes segment alignment to center")
    func updateAlignment_changesAlignmentToCenter() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.updateAlignment(.center, for: id)
        guard case .text(_, _, let alignment) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        #expect(alignment == .center)
    }

    @Test("updateAlignment marks model as dirty")
    func updateAlignment_marksDirty() {
        let model = iOSNoteEditorModel()
        model.isDirty = false
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.updateAlignment(.center, for: id)
        #expect(model.isDirty == true)
    }

    @Test("buildBodySegments encodes center alignment")
    func buildBodySegments_encodesCenterAlignment() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.updateText("Title\nBody text", for: id)
        model.updateAlignment(.center, for: id)
        let segs = model.buildBodySegments()
        #expect(segs.count == 1)
        #expect(segs[0].content == "Body text")
        #expect(segs[0].alignment == "center")
    }

    @Test("buildBodySegments uses nil alignment for leading")
    func buildBodySegments_nilAlignmentForLeading() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.updateText("Title\nBody text", for: id)
        let segs = model.buildBodySegments()
        #expect(segs.count == 1)
        #expect(segs[0].alignment == nil)
    }

    @Test("encode then decode round-trips center alignment")
    func bodySeg_roundTrips_centerAlignment() {
        let original = [BodySegment(kind: .text, content: "Hello", path: nil, alignment: "center")]
        let encoded = iOSNoteEditorModel.encodeBodySegments(original)
        let decoded = iOSNoteEditorModel.decodeBodySegments(from: encoded)
        #expect(decoded?.first?.alignment == "center")
    }

    @Test("decode old body JSON without alignment field defaults to nil")
    func bodySeg_decodeOldFormat_nilAlignment() {
        let oldJSON = #"[{"kind":"text","content":"Hello"}]"#
        let decoded = iOSNoteEditorModel.decodeBodySegments(from: oldJSON)
        #expect(decoded?.first?.alignment == nil)
    }
}
