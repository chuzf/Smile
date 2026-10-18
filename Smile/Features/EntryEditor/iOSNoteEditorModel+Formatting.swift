import Foundation

/// 发起整理时的文字快照；写回时按 id 对应，照片和对齐方式不参与
struct FormattingSnapshot: Equatable {
    let input: FormattingInput
    let textSegmentIDs: [UUID]   // 与 input.segments 一一对应；[0] 是承载标题的首个文字段
    let layout: [Block]          // 文字段与照片的排列，供预览显示照片占位

    enum Block: Equatable { case text(Int), photo }
}

extension iOSNoteEditorModel {
    func formattingSnapshot() -> FormattingSnapshot? {
        var title = ""
        var parts: [String] = []
        var ids: [UUID] = []
        var layout: [FormattingSnapshot.Block] = []
        for seg in segments {
            switch seg {
            case .text(let id, let content, _):
                if ids.isEmpty {
                    // 与 extractTitle() 一致：首个文字段的第一行是标题
                    let lines = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    title = lines.first.map(String.init) ?? ""
                    parts.append(lines.count > 1 ? String(lines[1]) : "")
                } else {
                    parts.append(content)
                }
                layout.append(.text(ids.count))
                ids.append(id)
            case .photo:
                layout.append(.photo)
            }
        }
        guard !ids.isEmpty else { return nil }
        return FormattingSnapshot(input: FormattingInput(title: title, segments: parts),
                                  textSegmentIDs: ids, layout: layout)
    }

    var canFormat: Bool {
        guard let input = formattingSnapshot()?.input else { return false }
        return ([input.title] + input.segments).contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 段数不符或快照里的文字段已不存在时不做任何修改，返回 false
    @discardableResult
    func applyFormatting(_ result: FormattingResult, to snapshot: FormattingSnapshot) -> Bool {
        guard result.segments.count == snapshot.textSegmentIDs.count else { return false }
        let currentIDs = Set(segments.compactMap { seg -> UUID? in
            if case .text(let id, _, _) = seg { return id } else { return nil }
        })
        guard snapshot.textSegmentIDs.allSatisfy(currentIDs.contains) else { return false }

        let title = result.title.replacingOccurrences(of: "\n", with: " ")
        for (index, id) in snapshot.textSegmentIDs.enumerated() {
            let body = result.segments[index]
            let content = index == 0 ? (body.isEmpty ? title : title + "\n" + body) : body
            updateText(content, for: id)
        }
        isDirty = true
        return true
    }
}
