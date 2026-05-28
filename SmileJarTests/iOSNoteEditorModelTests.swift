import Testing
import SwiftData
@testable import SmileJar

@Suite("iOS Note Editor Model")
struct iOSNoteEditorModelTests {

    @Test("Extract title and body with title only")
    func extractTitleAndBody_withTitleOnly() {
        let model = iOSNoteEditorModel()
        model.editorText = "我的标题"
        let (title, body) = model.extractTitleAndBody()

        #expect(title == "我的标题")
        #expect(body == "")
    }

    @Test("Extract title and body with title and body")
    func extractTitleAndBody_withTitleAndBody() {
        let model = iOSNoteEditorModel()
        model.editorText = "我的标题\n这是正文"
        let (title, body) = model.extractTitleAndBody()

        #expect(title == "我的标题")
        #expect(body == "这是正文")
    }

    @Test("Extract title and body with multiline body")
    func extractTitleAndBody_withMultilineBody() {
        let model = iOSNoteEditorModel()
        model.editorText = "标题\n第一行\n第二行\n第三行"
        let (title, body) = model.extractTitleAndBody()

        #expect(title == "标题")
        #expect(body == "第一行\n第二行\n第三行")
    }

    @Test("Extract title and body with empty text")
    func extractTitleAndBody_emptyText() {
        let model = iOSNoteEditorModel()
        model.editorText = ""
        let (title, body) = model.extractTitleAndBody()

        #expect(title == "")
        #expect(body == "")
    }

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
        model.editorText = "some text"
        model.isDirty = true

        model.reset()

        #expect(model.editorText == "")
        #expect(model.isDirty == false)
        #expect(model.selectedGroupID == nil)
    }
}
