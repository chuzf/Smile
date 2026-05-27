import Foundation
import SwiftData

enum SearchService {

    /// 在指定分组(nil 为全局)内全文搜索,返回按 createdAt 倒序的 Entry 列表
    @MainActor
    static func search(in context: ModelContext, query: String, group: Group?) throws -> [Entry] {
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
            entry.title.localizedStandardContains(trimmed) ||
            entry.bodyText.localizedStandardContains(trimmed) ||
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
