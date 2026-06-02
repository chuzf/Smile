import Foundation
import Testing
@testable import Smile

@Suite("iOSNoteEditorModel Dictation")
struct iOSNoteEditorModelDictationTests {

    // MARK: updateDictation

    @Test("updateDictation 用 baseText+partial 替换当前段落文字")
    func updateDictation_replacesWithBaseAndPartial() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.updateText("你好 ", for: id)
        model.dictationTargetSegmentID = id
        model.dictationBaseText = "你好 "

        model.updateDictation("世界")

        #expect(model.textContent(for: id) == "你好 世界")
    }

    @Test("updateDictation 第二次调用替换上一次 partial")
    func updateDictation_replacesWithLatestPartial() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.dictationTargetSegmentID = id
        model.dictationBaseText = ""

        model.updateDictation("世界")
        model.updateDictation("世界你好")

        #expect(model.textContent(for: id) == "世界你好")
    }

    @Test("updateDictation 当 base 末尾无空格时自动补空格")
    func updateDictation_addsSpaceWhenNeeded() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.updateText("你好", for: id)
        model.dictationTargetSegmentID = id
        model.dictationBaseText = "你好"

        model.updateDictation("世界")

        #expect(model.textContent(for: id) == "你好 世界")
    }

    @Test("updateDictation 当 base 末尾是换行时不补空格")
    func updateDictation_noSpaceAfterNewline() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.updateText("你好\n", for: id)
        model.dictationTargetSegmentID = id
        model.dictationBaseText = "你好\n"

        model.updateDictation("世界")

        #expect(model.textContent(for: id) == "你好\n世界")
    }

    @Test("updateDictation 当 targetSegmentID 为 nil 时为 no-op")
    func updateDictation_noopWithoutTarget() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.updateText("你好", for: id)
        // dictationTargetSegmentID 默认为 nil

        model.updateDictation("世界")

        #expect(model.textContent(for: id) == "你好")
    }

    // MARK: commitDictation

    @Test("commitDictation 设置最终文字并清理状态")
    func commitDictation_setsFinalTextAndClearsState() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.updateText("你好", for: id)
        model.dictationTargetSegmentID = id
        model.dictationBaseText = "你好"
        model.isDirty = false

        model.commitDictation("世界")

        #expect(model.textContent(for: id) == "你好 世界")
        #expect(model.dictationTargetSegmentID == nil)
        #expect(model.dictationBaseText == "")
        #expect(model.isDirty == true)
    }

    @Test("commitDictation base 末尾有空格时不重复添加")
    func commitDictation_noDoubleSpace() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.dictationTargetSegmentID = id
        model.dictationBaseText = "你好 "

        model.commitDictation("世界")

        #expect(model.textContent(for: id) == "你好 世界")
    }

    // MARK: finalizeDictation

    @Test("finalizeDictation 保留当前文字并清理状态")
    func finalizeDictation_keepsCurrentTextAndClearsState() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.updateText("你好 世界", for: id) // partial 已写入
        model.dictationTargetSegmentID = id
        model.dictationBaseText = "你好 "
        model.isDirty = false

        model.finalizeDictation()

        #expect(model.textContent(for: id) == "你好 世界") // 不变
        #expect(model.dictationTargetSegmentID == nil)
        #expect(model.dictationBaseText == "")
        #expect(model.isDirty == true)
    }

    // MARK: cancelDictation

    @Test("cancelDictation 回滚到 baseText 并清理状态")
    func cancelDictation_revertsToBaseText() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.updateText("你好 世界", for: id) // partial 已写入
        model.dictationTargetSegmentID = id
        model.dictationBaseText = "你好 "
        model.isDirty = false

        model.cancelDictation()

        #expect(model.textContent(for: id) == "你好 ")
        #expect(model.dictationTargetSegmentID == nil)
        #expect(model.dictationBaseText == "")
        #expect(model.isDirty == false)
    }

    @Test("cancelDictation 当 targetSegmentID 为 nil 时为 no-op")
    func cancelDictation_noopWithoutTarget() {
        let model = iOSNoteEditorModel()
        guard case .text(let id, _, _) = model.segments.first else {
            Issue.record("Expected first segment to be text"); return
        }
        model.updateText("你好", for: id)
        model.dictationBaseText = "should not matter"

        model.cancelDictation()

        #expect(model.textContent(for: id) == "你好")
        #expect(model.dictationBaseText == "")
    }
}
