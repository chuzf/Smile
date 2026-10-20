import XCTest
@testable import Smile

final class EditorModelTests: XCTestCase {

    private func makeDraft(relativePath: String) -> DraftAttachment {
        DraftAttachment(persistedID: nil, kind: .photo, relativePath: relativePath, transcript: nil, durationSeconds: nil)
    }

    func testInsertPhotosAfterAnchorPreservesOrder() {
        let model = iOSNoteEditorModel()
        let anchorID: UUID
        if case .text(let id, _, _) = model.segments[0] { anchorID = id }
        else { XCTFail("Expected text segment"); return }

        let d1 = makeDraft(relativePath: "a.jpg")
        let d2 = makeDraft(relativePath: "b.jpg")
        let d3 = makeDraft(relativePath: "c.jpg")
        model.insertPhotos([d1, d2, d3], at: InsertionPoint(segmentID: anchorID, offset: .max))

        let photos = model.photoDrafts
        XCTAssertEqual(photos.count, 3)
        XCTAssertEqual(photos[0].relativePath, "a.jpg")
        XCTAssertEqual(photos[1].relativePath, "b.jpg")
        XCTAssertEqual(photos[2].relativePath, "c.jpg")
    }

    func testInsertPhotosWithoutAnchorAppendsInOrder() {
        let model = iOSNoteEditorModel()
        let d1 = makeDraft(relativePath: "x.jpg")
        let d2 = makeDraft(relativePath: "y.jpg")
        model.insertPhotos([d1, d2], at: nil)

        let photos = model.photoDrafts
        XCTAssertEqual(photos.count, 2)
        XCTAssertEqual(photos[0].relativePath, "x.jpg")
        XCTAssertEqual(photos[1].relativePath, "y.jpg")
    }

    func testInsertPhotosEmptyDraftsDoesNothing() {
        let model = iOSNoteEditorModel()
        let initialCount = model.segments.count
        model.insertPhotos([], at: nil)
        XCTAssertEqual(model.segments.count, initialCount)
    }

    func testInsertPhotosInvalidAnchorFallsBackToAppend() {
        let model = iOSNoteEditorModel()
        let fakeID = UUID()
        let d1 = makeDraft(relativePath: "x.jpg")
        model.insertPhotos([d1], at: InsertionPoint(segmentID: fakeID, offset: 0))
        // Should fall back to append, not crash
        XCTAssertEqual(model.photoDrafts.count, 1)
        XCTAssertEqual(model.photoDrafts[0].relativePath, "x.jpg")
    }

    func testInsertPhotosSegmentStructureIsPhotoTextInterleaved() {
        let model = iOSNoteEditorModel()
        let anchorID: UUID
        if case .text(let id, _, _) = model.segments[0] { anchorID = id }
        else { XCTFail("Expected text segment"); return }

        let d1 = makeDraft(relativePath: "a.jpg")
        let d2 = makeDraft(relativePath: "b.jpg")
        model.insertPhotos([d1, d2], at: InsertionPoint(segmentID: anchorID, offset: .max))

        // Expected: [text(anchor), photo(a), text, photo(b), text]
        XCTAssertEqual(model.segments.count, 5)
        if case .text = model.segments[0] { } else { XCTFail("seg[0] should be text") }
        if case .photo(let d) = model.segments[1] { XCTAssertEqual(d.relativePath, "a.jpg") } else { XCTFail("seg[1] should be photo a") }
        if case .text = model.segments[2] { } else { XCTFail("seg[2] should be text") }
        if case .photo(let d) = model.segments[3] { XCTAssertEqual(d.relativePath, "b.jpg") } else { XCTFail("seg[3] should be photo b") }
        if case .text = model.segments[4] { } else { XCTFail("seg[4] should be text") }
    }

    // MARK: 在光标处插入

    private func texts(_ model: iOSNoteEditorModel) -> [String?] {
        model.segments.map {
            if case .text(_, let c, _) = $0 { return c } else { return nil }
        }
    }

    private func firstID(_ model: iOSNoteEditorModel) -> UUID {
        model.segments[0].id
    }

    func testInsertAtLineStartSplitsBetweenLines() {
        let model = iOSNoteEditorModel()
        model.updateText("标题\n第一段\n第二段", for: firstID(model))
        // 光标在「第二段」行首
        let offset = ("标题\n第一段\n" as NSString).length
        model.insertPhotos([makeDraft(relativePath: "a.jpg")], at: InsertionPoint(segmentID: firstID(model), offset: offset))
        XCTAssertEqual(texts(model), ["标题\n第一段", nil, "第二段"])
    }

    func testInsertAtLineEndSplitsBetweenLines() {
        let model = iOSNoteEditorModel()
        model.updateText("标题\n第一段\n第二段", for: firstID(model))
        let offset = ("标题\n第一段" as NSString).length
        model.insertPhotos([makeDraft(relativePath: "a.jpg")], at: InsertionPoint(segmentID: firstID(model), offset: offset))
        XCTAssertEqual(texts(model), ["标题\n第一段", nil, "第二段"])
    }

    func testInsertInMiddleOfLineSplitsLine() {
        let model = iOSNoteEditorModel()
        model.updateText("标题\nabcd", for: firstID(model))
        model.insertPhotos([makeDraft(relativePath: "a.jpg")], at: InsertionPoint(segmentID: firstID(model), offset: 5))
        XCTAssertEqual(texts(model), ["标题\nab", nil, "cd"])
    }

    func testInsertInsideTitleGoesAfterTitle() {
        let model = iOSNoteEditorModel()
        model.updateText("标题\n正文", for: firstID(model))
        model.insertPhotos([makeDraft(relativePath: "a.jpg")], at: InsertionPoint(segmentID: firstID(model), offset: 1))
        XCTAssertEqual(texts(model), ["标题", nil, "正文"])
        XCTAssertEqual(model.extractTitle(), "标题")
    }

    func testConsecutiveInsertsKeepOrderAtCursor() {
        let model = iOSNoteEditorModel()
        model.updateText("标题\n上\n下", for: firstID(model))
        let offset = ("标题\n上" as NSString).length
        model.insertPhotos([makeDraft(relativePath: "a.jpg")], at: InsertionPoint(segmentID: firstID(model), offset: offset))
        model.insertPhotos([makeDraft(relativePath: "b.jpg")], at: model.insertionPoint)
        XCTAssertEqual(model.photoDrafts.map(\.relativePath), ["a.jpg", "b.jpg"])
        XCTAssertEqual(texts(model), ["标题\n上", nil, "", nil, "下"])
    }

    func testInsertionPointFollowsMergeAfterPhotoRemoval() {
        let model = iOSNoteEditorModel()
        model.updateText("标题\n上", for: firstID(model))
        model.insertPhotos([makeDraft(relativePath: "a.jpg")], at: InsertionPoint(segmentID: firstID(model), offset: .max))
        guard case .photo(let photo) = model.segments[1] else { return XCTFail("seg[1] should be photo") }
        model.updateText("下文", for: model.segments[2].id)
        model.insertionPoint = InsertionPoint(segmentID: model.segments[2].id, offset: 1)
        model.removePhoto(id: photo.id)
        // 合并后为「标题\n上\n下文」，插入点仍在「下」之后
        XCTAssertEqual(model.insertionPoint, InsertionPoint(segmentID: firstID(model), offset: ("标题\n上\n下" as NSString).length))
    }
}
