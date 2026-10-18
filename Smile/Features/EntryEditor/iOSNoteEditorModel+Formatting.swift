import Foundation

/// 发起整理时的文字快照；写回时按 id 对应，照片和对齐方式不参与
struct FormattingSnapshot: Equatable {
    let input: FormattingInput
    let textSegmentIDs: [UUID]   // 与 input.segments 一一对应；[0] 是承载标题的首个文字段
    let originalContents: [String] // 各文字段取快照时的完整内容；写回前比对，有变化就拒绝
    let centered: [Bool]         // 各文字段是否居中；居中段落不加段首缩进
    let layout: [Block]          // 文字段与照片的排列，供预览显示照片占位

    enum Block: Equatable { case text(Int), photo }

    /// 去掉居中文字段每段开头的缩进，段间空行保留
    func adjustingIndent(_ result: FormattingResult) -> FormattingResult {
        var adjusted = result
        for index in adjusted.segments.indices where centered.indices.contains(index) && centered[index] {
            adjusted.segments[index] = adjusted.segments[index]
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0.drop(while: \.isWhitespace)) }
                .joined(separator: "\n")
        }
        return adjusted
    }
}

extension iOSNoteEditorModel {
    func formattingSnapshot() -> FormattingSnapshot? {
        var title = ""
        var parts: [String] = []
        var ids: [UUID] = []
        var originals: [String] = []
        var centered: [Bool] = []
        var layout: [FormattingSnapshot.Block] = []
        for seg in segments {
            switch seg {
            case .text(let id, let content, let alignment):
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
                originals.append(content)
                centered.append(alignment == .center)
            case .photo:
                layout.append(.photo)
            }
        }
        guard !ids.isEmpty else { return nil }
        return FormattingSnapshot(input: FormattingInput(title: title, segments: parts),
                                  textSegmentIDs: ids, originalContents: originals,
                                  centered: centered, layout: layout)
    }

    var canFormat: Bool {
        guard let input = formattingSnapshot()?.input else { return false }
        return ([input.title] + input.segments).contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 段数不符、快照里的文字段已不存在或内容已变化时不做任何修改，返回 false
    @discardableResult
    func applyFormatting(_ result: FormattingResult, to snapshot: FormattingSnapshot) -> Bool {
        guard result.segments.count == snapshot.textSegmentIDs.count else { return false }
        var current: [UUID: String] = [:]
        for seg in segments {
            if case .text(let id, let content, _) = seg { current[id] = content }
        }
        guard zip(snapshot.textSegmentIDs, snapshot.originalContents).allSatisfy({ current[$0] == $1 }) else {
            return false
        }

        // 按 Character 拆分："\r\n" 是一个字符，不会变成两个空格
        let title = result.title.split(whereSeparator: \.isNewline).joined(separator: " ")
        for (index, id) in snapshot.textSegmentIDs.enumerated() {
            let body = result.segments[index]
            let content = index == 0 ? (body.isEmpty ? title : title + "\n" + body) : body
            updateText(content, for: id)
        }
        isDirty = true
        return true
    }
}
