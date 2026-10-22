import Foundation
import SwiftData

enum SearchService {

    /// 在指定分组(nil 为全局)内全文搜索,返回按 createdAt 倒序的 Entry 列表。
    /// isSearchable 返回 false 的条目（未解锁的加锁内容）完全不参与匹配，避免靠「搜得到」反推内容
    @MainActor
    static func search(in context: ModelContext, query: String, group: Group?,
                       isSearchable: (Entry) -> Bool = { _ in true }) throws -> [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var descriptor = FetchDescriptor<Entry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        // SwiftData iOS 17 的 #Predicate 对 localizedStandardContains 支持不稳定,
        // 因此 group 维度用 predicate 收窄,文本匹配整体走内存过滤。
        if let group = group {
            let groupID = group.id
            descriptor.predicate = #Predicate<Entry> { entry in
                entry.group?.id == groupID
            }
        }

        let entries = try context.fetch(descriptor)

        // SwiftData #Predicate 还不支持 transcript / tags 关联文本查询,内存里再过一遍
        if trimmed.isEmpty { return entries }
        return entries.filter { entry in
            guard isSearchable(entry) else { return false }
            // bodyText 存的是分段 JSON，只在正文文字上匹配，免得搜 "photo"/"jpg" 命中字段名和文件名
            return entry.title.localizedStandardContains(trimmed) ||
            iOSNoteEditorModel.plainText(from: entry.bodyText).localizedStandardContains(trimmed) ||
            entry.attachments.contains { $0.transcript?.localizedStandardContains(trimmed) ?? false } ||
            entry.tags.contains { $0.name.localizedStandardContains(trimmed) }
        }
    }

    /// 按时间区间筛选
    @MainActor
    static func filter(in context: ModelContext, group: Group?, from: Date?, to: Date?) throws -> [Entry] {
        var descriptor = FetchDescriptor<Entry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        if let groupID = group?.id {
            descriptor.predicate = #Predicate<Entry> { entry in
                entry.group?.id == groupID
            }
        }

        let entries = try context.fetch(descriptor)
        return entries.filter { entry in
            (from.map { entry.createdAt >= $0 } ?? true) &&
            (to.map { entry.createdAt <= $0 } ?? true)
        }
    }
}
