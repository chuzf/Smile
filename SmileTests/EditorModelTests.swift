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
}
