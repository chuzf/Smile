import Testing
import SwiftData
@testable import SmileJar

@Suite("DataModel")
struct DataModelTests {

    @Test("In-memory container 可创建")
    @MainActor func containerCreates() throws {
        let container = try ModelContainerFactory.makeInMemory()
        #expect(container.mainContext.container === container)
    }

    @Test("首次启动 seed 两个内置分组")
    @MainActor func seedsBuiltinGroups() throws {
        let container = try ModelContainerFactory.makeInMemory()
        ModelContainerFactory.seedIfNeeded(context: container.mainContext)

        let groups = try container.mainContext.fetch(FetchDescriptor<Group>())
        #expect(groups.count == 2)
        #expect(groups.contains { $0.name == "微笑储蓄罐" && $0.isBuiltIn })
        #expect(groups.contains { $0.name == "优势储蓄罐" && $0.isBuiltIn })
    }

    @Test("重复调用 seed 不会创建多份")
    @MainActor func seedIsIdempotent() throws {
        let container = try ModelContainerFactory.makeInMemory()
        ModelContainerFactory.seedIfNeeded(context: container.mainContext)
        ModelContainerFactory.seedIfNeeded(context: container.mainContext)

        let groups = try container.mainContext.fetch(FetchDescriptor<Group>())
        #expect(groups.count == 2)
    }

    @Test("内置分组不可删除")
    @MainActor func builtInGroupCannotDelete() throws {
        let container = try ModelContainerFactory.makeInMemory()
        ModelContainerFactory.seedIfNeeded(context: container.mainContext)
        let groups = try container.mainContext.fetch(FetchDescriptor<Group>())
        let builtin = groups.first { $0.isBuiltIn }!
        #expect(builtin.canDelete == false)
    }

    @Test("非空自定义分组不可删除")
    @MainActor func nonEmptyCustomGroupCannotDelete() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let group = Group(name: "自定义", iconSymbol: "star", colorHex: "#FF0000", isBuiltIn: false)
        let entry = Entry(title: "条目", group: group)
        group.entries.append(entry)
        ctx.insert(group)
        ctx.insert(entry)
        try ctx.save()
        #expect(group.canDelete == false)
    }

    @Test("空的自定义分组可删除")
    @MainActor func emptyCustomGroupCanDelete() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let group = Group(name: "自定义", iconSymbol: "star", colorHex: "#FF0000", isBuiltIn: false)
        ctx.insert(group)
        try ctx.save()
        #expect(group.canDelete == true)
    }

    @Test("无初始分组时默认选微笑储蓄罐")
    @MainActor func defaultsToSmileJarWhenNoInitialGroup() throws {
        let container = try ModelContainerFactory.makeInMemory()
        ModelContainerFactory.seedIfNeeded(context: container.mainContext)
        let groups = try container.mainContext.fetch(FetchDescriptor<Group>())
        let smile = groups.first { $0.name == "微笑储蓄罐" }!

        let model = EntryEditorModel()
        model.selectDefaultGroup(from: groups, initialGroupID: nil)

        #expect(model.selectedGroupID == smile.persistentModelID)
    }

    @Test("从特定储蓄罐打开时默认选中该储蓄罐")
    @MainActor func initialGroupIDIsPreselected() throws {
        let container = try ModelContainerFactory.makeInMemory()
        ModelContainerFactory.seedIfNeeded(context: container.mainContext)
        let groups = try container.mainContext.fetch(FetchDescriptor<Group>())
        let strength = groups.first { $0.name == "优势储蓄罐" }!

        let model = EntryEditorModel()
        model.selectDefaultGroup(from: groups, initialGroupID: strength.persistentModelID)

        #expect(model.selectedGroupID == strength.persistentModelID)
    }

    @Test("删除 Entry 级联清掉 MediaAttachment")
    @MainActor func cascadeDeleteAttachments() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext

        let group = Group(name: "测试", iconSymbol: "star", colorHex: "#FF0000")
        let entry = Entry(title: "条目", group: group)
        let att = MediaAttachment(kind: .photo, relativePath: "x/y.heic")
        att.entry = entry
        entry.attachments.append(att)

        ctx.insert(group)
        ctx.insert(entry)
        ctx.insert(att)
        try ctx.save()

        #expect(try ctx.fetch(FetchDescriptor<MediaAttachment>()).count == 1)

        ctx.delete(entry)
        try ctx.save()

        #expect(try ctx.fetch(FetchDescriptor<MediaAttachment>()).count == 0)
    }
}
