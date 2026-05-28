import XCTest
@testable import SmileJar

final class iOSNoteEditorModelTests: XCTestCase {
    var model: iOSNoteEditorModel!

    override func setUp() {
        super.setUp()
        model = iOSNoteEditorModel()
    }

    func test_extractTitleAndBody_withTitleOnly() {
        model.editorText = "我的标题"
        let (title, body) = model.extractTitleAndBody()

        XCTAssertEqual(title, "我的标题")
        XCTAssertEqual(body, "")
    }

    func test_extractTitleAndBody_withTitleAndBody() {
        model.editorText = "我的标题\n这是正文"
        let (title, body) = model.extractTitleAndBody()

        XCTAssertEqual(title, "我的标题")
        XCTAssertEqual(body, "这是正文")
    }

    func test_extractTitleAndBody_withMultilineBody() {
        model.editorText = "标题\n第一行\n第二行\n第三行"
        let (title, body) = model.extractTitleAndBody()

        XCTAssertEqual(title, "标题")
        XCTAssertEqual(body, "第一行\n第二行\n第三行")
    }

    func test_extractTitleAndBody_emptyText() {
        model.editorText = ""
        let (title, body) = model.extractTitleAndBody()

        XCTAssertEqual(title, "")
        XCTAssertEqual(body, "")
    }

    func test_scheduleAutoSave_setsDirtyFlag() {
        model.isDirty = false
        model.scheduleAutoSave()

        XCTAssertTrue(model.isDirty)
    }

    func test_reset_clearsAllState() {
        model.editorText = "some text"
        model.isDirty = true
        model.selectedGroupID = UUID().uuidString as! PersistentIdentifier

        model.reset()

        XCTAssertEqual(model.editorText, "")
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(model.selectedGroupID)
    }
}
