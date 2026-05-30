import Foundation
import Testing
import SwiftData
@testable import SmileJar

@Suite("iOS Note Editor Model")
struct iOSNoteEditorModelTests {

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

    @Test("updateAlignment with unknown ID is a no-op")
    func updateAlignment_unknownID_isNoOp() {
        let model = iOSNoteEditorModel()
        model.isDirty = false
        model.updateAlignment(.center, for: UUID())
        #expect(model.isDirty == false)
        guard case .text(_, _, let alignment) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        #expect(alignment == .leading)
    }
}
