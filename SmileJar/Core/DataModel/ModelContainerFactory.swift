import Foundation
import SwiftData

enum ModelContainerFactory {

    /// 生产环境容器(磁盘持久化)
    static func makeShared() throws -> ModelContainer {
        let schema = Schema([Group.self, Entry.self, MediaAttachment.self, Tag.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// 测试用内存容器
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema([Group.self, Entry.self, MediaAttachment.self, Tag.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// 仅当 Group 表为空时插入两个内置分组
    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<Group>()
        let existing = (try? context.fetch(descriptor)) ?? []
        guard existing.isEmpty else { return }

        let smile = Group(
            name: "微笑储蓄罐",
            iconSymbol: "face.smiling",
            colorHex: "#E08A4A",
            isBuiltIn: true,
            sortOrder: 0
        )
        let strength = Group(
            name: "优势储蓄罐",
            iconSymbol: "sparkles",
            colorHex: "#7AA350",
            isBuiltIn: true,
            sortOrder: 1
        )
        context.insert(smile)
        context.insert(strength)
        try? context.save()
    }
}
