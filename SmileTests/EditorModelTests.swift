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
        model.insertPhotos([d1, d2, d3], afterSegmentID: anchorID)

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
        model.insertPhotos([d1, d2], afterSegmentID: nil)

        let photos = model.photoDrafts
        XCTAssertEqual(photos.count, 2)
        XCTAssertEqual(photos[0].relativePath, "x.jpg")
        XCTAssertEqual(photos[1].relativePath, "y.jpg")
    }

    func testInsertPhotosEmptyDraftsDoesNothing() {
        let model = iOSNoteEditorModel()
        let initialCount = model.segments.count
        model.insertPhotos([], afterSegmentID: nil)
        XCTAssertEqual(model.segments.count, initialCount)
    }

    func testInsertPhotosInvalidAnchorFallsBackToAppend() {
        let model = iOSNoteEditorModel()
        let fakeID = UUID()
        let d1 = makeDraft(relativePath: "x.jpg")
        model.insertPhotos([d1], afterSegmentID: fakeID)
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
        model.insertPhotos([d1, d2], afterSegmentID: anchorID)

        // Expected: [text(anchor), photo(a), text, photo(b), text]
        XCTAssertEqual(model.segments.count, 5)
        if case .text = model.segments[0] { } else { XCTFail("seg[0] should be text") }
        if case .photo(let d) = model.segments[1] { XCTAssertEqual(d.relativePath, "a.jpg") } else { XCTFail("seg[1] should be photo a") }
        if case .text = model.segments[2] { } else { XCTFail("seg[2] should be text") }
        if case .photo(let d) = model.segments[3] { XCTAssertEqual(d.relativePath, "b.jpg") } else { XCTFail("seg[3] should be photo b") }
        if case .text = model.segments[4] { } else { XCTFail("seg[4] should be text") }
    }
}
