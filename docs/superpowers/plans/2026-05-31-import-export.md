# 导入/导出功能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增从 .zip 备份导入数据功能，并修复导出失败时无用户提示的问题。

**Architecture:** 新建 `ImportService`（与 `ExportService` 对称），通过 ZIPFoundation 解压备份包，按"合并优先"策略将数据导入目标设备：内置分组按名称匹配避免 UUID 冲突，条目按 UUID 查重、按 `updatedAt` 决定是否覆盖。UI 入口放在 SettingsView，与导出按钮并排。

**Tech Stack:** SwiftUI, SwiftData, ZIPFoundation (new SPM dep), iOS 17+

---

## 文件清单

| 操作 | 路径 |
|------|------|
| 修改 | `Smile.xcodeproj/project.pbxproj` |
| 创建 | `Smile/Core/Import/ImportService.swift` |
| 创建 | `SmileTests/ImportServiceTests.swift` |
| 修改 | `Smile/Features/Settings/SettingsView.swift` |

---

## Task 1: 添加 ZIPFoundation SPM 依赖

**Files:**
- Modify: `Smile.xcodeproj/project.pbxproj`

- [ ] **Step 1: 在 pbxproj 的 XCRemoteSwiftPackageReference section 添加 ZIPFoundation**

找到文件中：
```
/* Begin XCRemoteSwiftPackageReference section */
		9EAE1A9F3055A062FAC535F8 /* XCRemoteSwiftPackageReference "swift-snapshot-testing" */ = {
```

在它下方（`/* End XCRemoteSwiftPackageReference section */` 之前）插入：
```
		A3F8C2D16E4B905782316C1D /* XCRemoteSwiftPackageReference "ZIPFoundation" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/weichsel/ZIPFoundation";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 0.9.19;
			};
		};
```

- [ ] **Step 2: 在 XCSwiftPackageProductDependency section 添加条目**

找到：
```
/* Begin XCSwiftPackageProductDependency section */
		64E19F4C2596F285C9524497 /* SnapshotTesting */ = {
```

在它下方（`/* End XCSwiftPackageProductDependency section */` 之前）插入：
```
		B7E4A19302F5C86D94B2E3F8 /* ZIPFoundation */ = {
			isa = XCSwiftPackageProductDependency;
			package = A3F8C2D16E4B905782316C1D /* XCRemoteSwiftPackageReference "ZIPFoundation" */;
			productName = ZIPFoundation;
		};
```

- [ ] **Step 3: 把包引用加入 project 的 packageReferences 列表**

找到：
```
			packageReferences = (
				9EAE1A9F3055A062FAC535F8 /* XCRemoteSwiftPackageReference "swift-snapshot-testing" */,
			);
```

改为：
```
			packageReferences = (
				9EAE1A9F3055A062FAC535F8 /* XCRemoteSwiftPackageReference "swift-snapshot-testing" */,
				A3F8C2D16E4B905782316C1D /* XCRemoteSwiftPackageReference "ZIPFoundation" */,
			);
```

- [ ] **Step 4: 把产品依赖加入 Smile target 的 packageProductDependencies**

找到（Smile target，非 SmileTests）：
```
			name = Smile;
			packageProductDependencies = (
			);
```

改为：
```
			name = Smile;
			packageProductDependencies = (
				B7E4A19302F5C86D94B2E3F8 /* ZIPFoundation */,
			);
```

- [ ] **Step 5: 解析并拉取包**

```bash
cd /Users/chuzhanfeng/work/claude/smile
xcodebuild -resolvePackageDependencies -project Smile.xcodeproj -scheme Smile
```

Expected: `Resolve Package Graph` 成功，无错误。

- [ ] **Step 6: 验证编译通过**

```bash
xcodebuild build -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 16' -quiet
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Smile.xcodeproj/project.pbxproj
git commit -m "chore: add ZIPFoundation SPM dependency"
```

---

## Task 2: 修复导出失败无提示问题

**Files:**
- Modify: `Smile/Features/Settings/SettingsView.swift`

- [ ] **Step 1: 修改 SettingsView，加入 exportError 状态和 Alert**

将整个文件替换为：

```swift
import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context

    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        Form {
            Section("功能") {
                NavigationLink("AI 自动标题") { AISettingsView() }
            }
            Section("数据") {
                Button {
                    Task { await exportAll() }
                } label: {
                    HStack {
                        Label("导出全部记录", systemImage: "square.and.arrow.up")
                        Spacer()
                        if exporting { ProgressView() }
                    }
                }
                .disabled(exporting)
            }
            Section("关于") {
                LabeledContent("版本") { Text("1.0") }
            }
        }
        .navigationTitle("���置")
        .sheet(item: Binding<ExportFileWrapper?>(
            get: { exportURL.map { ExportFileWrapper(url: $0) } },
            set: { _ in exportURL = nil }
        )) { w in
            ShareSheetForURL(url: w.url)
        }
        .alert("导出失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    @MainActor
    private func exportAll() async {
        exporting = true
        defer { exporting = false }
        do {
            let url = try ExportService.exportAll(
                context: context, mediaStore: .production()
            )
            exportURL = url
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct ExportFileWrapper: Identifiable {
    let id = UUID(); let url: URL
}

private struct ShareSheetForURL: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
```

- [ ] **Step 2: 编译验证**

```bash
xcodebuild build -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 16' -quiet
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Smile/Features/Settings/SettingsView.swift
git commit -m "fix: show alert when export fails"
```

---

## Task 3: 创建 ImportService 骨架（类型 + 私有工具函数）

**Files:**
- Create: `Smile/Core/Import/ImportService.swift`
- Create: `SmileTests/ImportServiceTests.swift`

- [ ] **Step 1: 写失败测试——不支持的 manifest 版本应抛出 unsupportedVersion**

创建 `SmileTests/ImportServiceTests.swift`：

```swift
import Testing
import Foundation
import SwiftData
@testable import Smile

@Suite("ImportService")
struct ImportServiceTests {

    // MARK: - Manifest version check

    @MainActor
    @Test func unsupportedVersionThrows() throws {
        // Build a zip with manifest.version = 99
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Manually craft a manifest with version 99
        let manifest = ["version": 99, "groupCount": 0, "entryCount": 0,
                        "exportedAt": "2026-01-01T00:00:00Z"] as [String: Any]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))
        try encoder.encode([String]()).write(to: staging.appendingPathComponent("groups.json"))
        try encoder.encode([String]()).write(to: staging.appendingPathComponent("entries.json"))
        try encoder.encode([String]()).write(to: staging.appendingPathComponent("tags.json"))

        // Zip it
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-v99-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }
        try ExportService.zipDirectory(staging, to: zipURL)

        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let store = MediaStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("media-\(UUID().uuidString)"))

        #expect(throws: ImportService.ImportError.self) {
            try ImportService.importBackup(from: zipURL, context: ctx, mediaStore: store)
        }
    }
}
```

- [ ] **Step 2: 运行测试，确认编译失败（ImportService 尚不存在）**

```bash
xcodebuild test -project Smile.xcodeproj -scheme SmileTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|FAILED|PASSED" | head -20
```

Expected: 编译错误（`ImportService` 不存在）

- [ ] **Step 3: 将 `zipDirectory` 改为 `internal` 以便测试调用**

`ExportService.swift` 中，将：
```swift
    private static func zipDirectory(_ src: URL, to dst: URL) throws {
```
改为：
```swift
    static func zipDirectory(_ src: URL, to dst: URL) throws {
```

- [ ] **Step 4: 创建 `Smile/Core/Import/ImportService.swift`**

```swift
import Foundation
import SwiftData
import ZIPFoundation

enum ImportService {

    struct ImportResult {
        let newGroups: Int
        let newEntries: Int
        let updatedEntries: Int
        let skippedEntries: Int
        let newTags: Int
    }

    enum ImportError: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case missingFile(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "不支持该备份版本（v\(v)），请更新 App 后重试"
            case .missingFile(let name):
                return "备份文件损坏：缺少 \(name)"
            }
        }
    }

    @MainActor
    static func importBackup(
        from zipURL: URL,
        context: ModelContext,
        mediaStore: MediaStore
    ) throws -> ImportResult {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("smilejar-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        try unzip(zipURL, to: staging)

        let manifest = try readJSON(ExportService.ExportManifest.self,
                                    filename: "manifest.json", in: staging)
        guard manifest.version == 1 else {
            throw ImportError.unsupportedVersion(manifest.version)
        }

        let groupDTOs = try readJSON([ExportService.GroupDTO].self,
                                     filename: "groups.json", in: staging)
        let entryDTOs = try readJSON([ExportService.EntryDTO].self,
                                     filename: "entries.json", in: staging)
        let tagDTOs   = try readJSON([ExportService.TagDTO].self,
                                     filename: "tags.json", in: staging)

        let existingGroups  = try context.fetch(FetchDescriptor<Group>())
        let existingEntries = try context.fetch(FetchDescriptor<Entry>())
        let existingTags    = try context.fetch(FetchDescriptor<Tag>())

        let (groupMap, newGroupCount) = buildGroupMap(
            dtos: groupDTOs, existing: existingGroups, context: context)
        let (tagMap, newTagCount) = buildTagMap(
            dtos: tagDTOs, existing: existingTags, context: context)

        let existingByID = Dictionary(uniqueKeysWithValues: existingEntries.map { ($0.id, $0) })
        let mediaDir = staging.appendingPathComponent("media")
        var newCount = 0, updatedCount = 0, skippedCount = 0

        for dto in entryDTOs {
            if let existing = existingByID[dto.id] {
                if dto.updatedAt > existing.updatedAt {
                    updateEntry(existing, from: dto,
                                groupMap: groupMap, tagMap: tagMap, context: context)
                    replaceMedia(entryID: dto.id, from: mediaDir, mediaStore: mediaStore)
                    updatedCount += 1
                } else {
                    skippedCount += 1
                }
            } else {
                insertEntry(from: dto, groupMap: groupMap,
                            tagMap: tagMap, context: context)
                copyMedia(entryID: dto.id, from: mediaDir, mediaStore: mediaStore)
                newCount += 1
            }
        }

        try context.save()

        return ImportResult(
            newGroups: newGroupCount,
            newEntries: newCount,
            updatedEntries: updatedCount,
            skippedEntries: skippedCount,
            newTags: newTagCount
        )
    }

    // MARK: - Private: zip + JSON helpers

    private static func unzip(_ zipURL: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: zipURL, to: destination)
    }

    private static func readJSON<T: Decodable>(
        _ type: T.Type, filename: String, in directory: URL
    ) throws -> T {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.missingFile(filename)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    // MARK: - Stubs (implemented in later tasks)

    @MainActor
    static func buildGroupMap(
        dtos: [ExportService.GroupDTO],
        existing: [Group],
        context: ModelContext
    ) -> ([UUID: Group], Int) { ([:], 0) }

    @MainActor
    static func buildTagMap(
        dtos: [ExportService.TagDTO],
        existing: [Tag],
        context: ModelContext
    ) -> ([String: Tag], Int) { ([:], 0) }

    @MainActor
    static func insertEntry(
        from dto: ExportService.EntryDTO,
        groupMap: [UUID: Group],
        tagMap: [String: Tag],
        context: ModelContext
    ) {}

    @MainActor
    static func updateEntry(
        _ entry: Entry,
        from dto: ExportService.EntryDTO,
        groupMap: [UUID: Group],
        tagMap: [String: Tag],
        context: ModelContext
    ) {}

    static func copyMedia(entryID: UUID, from mediaDir: URL, mediaStore: MediaStore) {}
    static func replaceMedia(entryID: UUID, from mediaDir: URL, mediaStore: MediaStore) {}
}
```

- [ ] **Step 5: 运行测试，确认 unsupportedVersionThrows 通过**

```bash
xcodebuild test -project Smile.xcodeproj -scheme SmileTests -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SmileTests/ImportServiceTests/unsupportedVersionThrows 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

Expected: `Test Case 'ImportServiceTests/unsupportedVersionThrows' passed`

- [ ] **Step 6: 把 ImportService.swift 加入 Xcode target**

在 `project.pbxproj` 中找到 Sources build phase for Smile target（含其他 `.swift` 文件的那一块）。参照现有条目格式，用新生成的 UUID 加入 `ImportService.swift`。

也可以在 Xcode 中 "Add Files" 操作，或用以下方式验证：
```bash
xcodebuild build -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Smile/Core/Import/ImportService.swift SmileTests/ImportServiceTests.swift Smile/Core/Export/ExportService.swift Smile.xcodeproj/project.pbxproj
git commit -m "feat: add ImportService skeleton with version check"
```

---

## Task 4: 实现 buildGroupMap

**Files:**
- Modify: `Smile/Core/Import/ImportService.swift`
- Modify: `SmileTests/ImportServiceTests.swift`

- [ ] **Step 1: 在 ImportServiceTests 末尾加入三个测试**

```swift
    // MARK: - buildGroupMap

    @MainActor
    @Test func builtInGroupRemappedByName() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        ModelContainerFactory.seedIfNeeded(context: ctx)
        let existing = try ctx.fetch(FetchDescriptor<Group>())
        let builtIn = existing.first(where: \.isBuiltIn)!

        // Simulate A's built-in group having a different UUID
        let srcGroup = Group(id: UUID(), name: builtIn.name,
                             iconSymbol: builtIn.iconSymbol, colorHex: builtIn.colorHex,
                             isBuiltIn: true, sortOrder: builtIn.sortOrder)
        let dto = ExportService.GroupDTO(srcGroup)

        let (map, newCount) = ImportService.buildGroupMap(
            dtos: [dto], existing: existing, context: ctx)

        #expect(map[dto.id]?.id == builtIn.id)  // maps to B's group, not A's UUID
        #expect(newCount == 0)
    }

    @MainActor
    @Test func existingCustomGroupSkipped() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let customGroup = Group(id: UUID(), name: "旅行", iconSymbol: "airplane",
                                colorHex: "#4A90E2", isBuiltIn: false, sortOrder: 5)
        ctx.insert(customGroup)
        try ctx.save()
        let existing = try ctx.fetch(FetchDescriptor<Group>())

        let dto = ExportService.GroupDTO(customGroup)  // same UUID
        let (map, newCount) = ImportService.buildGroupMap(
            dtos: [dto], existing: existing, context: ctx)

        #expect(map[dto.id]?.id == customGroup.id)
        #expect(newCount == 0)
        let groups = try ctx.fetch(FetchDescriptor<Group>())
        #expect(groups.count == 1)  // no duplicate inserted
    }

    @MainActor
    @Test func newCustomGroupInserted() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        // B has no groups
        let srcGroup = Group(id: UUID(), name: "旅行", iconSymbol: "airplane",
                             colorHex: "#4A90E2", isBuiltIn: false, sortOrder: 5)
        let dto = ExportService.GroupDTO(srcGroup)

        let (map, newCount) = ImportService.buildGroupMap(
            dtos: [dto], existing: [], context: ctx)

        #expect(map[dto.id] != nil)
        #expect(newCount == 1)
        let groups = try ctx.fetch(FetchDescriptor<Group>())
        #expect(groups.count == 1)
        #expect(groups[0].name == "旅行")
    }
```

- [ ] **Step 2: 运行测试，确认失败（stub 返回空映射）**

```bash
xcodebuild test -project Smile.xcodeproj -scheme SmileTests -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SmileTests/ImportServiceTests 2>&1 | grep -E "passed|failed"
```

Expected: `builtInGroupRemappedByName` 等三个测试 FAILED

- [ ] **Step 3: 用真实实现替换 buildGroupMap stub**

在 `ImportService.swift` 中，将 `buildGroupMap` 函数替换为：

```swift
    @MainActor
    static func buildGroupMap(
        dtos: [ExportService.GroupDTO],
        existing: [Group],
        context: ModelContext
    ) -> ([UUID: Group], Int) {
        let builtInByName = Dictionary(
            uniqueKeysWithValues: existing.filter(\.isBuiltIn).map { ($0.name, $0) })
        let customByID = Dictionary(
            uniqueKeysWithValues: existing.filter { !$0.isBuiltIn }.map { ($0.id, $0) })

        var map: [UUID: Group] = [:]
        var newCount = 0

        for dto in dtos {
            if dto.isBuiltIn {
                if let match = builtInByName[dto.name] {
                    map[dto.id] = match
                } else {
                    let g = Group(id: dto.id, name: dto.name,
                                  iconSymbol: dto.iconSymbol, colorHex: dto.colorHex,
                                  isBuiltIn: true, sortOrder: dto.sortOrder,
                                  createdAt: dto.createdAt)
                    context.insert(g)
                    map[dto.id] = g
                    newCount += 1
                }
            } else {
                if let match = customByID[dto.id] {
                    map[dto.id] = match
                } else {
                    let g = Group(id: dto.id, name: dto.name,
                                  iconSymbol: dto.iconSymbol, colorHex: dto.colorHex,
                                  isBuiltIn: false, sortOrder: dto.sortOrder,
                                  createdAt: dto.createdAt)
                    context.insert(g)
                    map[dto.id] = g
                    newCount += 1
                }
            }
        }
        return (map, newCount)
    }
```

- [ ] **Step 4: 运行测试，确认三个 buildGroupMap 测试通过**

```bash
xcodebuild test -project Smile.xcodeproj -scheme SmileTests -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SmileTests/ImportServiceTests 2>&1 | grep -E "passed|failed"
```

Expected: 全部 PASSED

- [ ] **Step 5: Commit**

```bash
git add Smile/Core/Import/ImportService.swift SmileTests/ImportServiceTests.swift
git commit -m "feat: implement buildGroupMap with built-in remapping"
```

---

## Task 5: 实现 buildTagMap

**Files:**
- Modify: `Smile/Core/Import/ImportService.swift`
- Modify: `SmileTests/ImportServiceTests.swift`

- [ ] **Step 1: 添加两个测试到 ImportServiceTests**

```swift
    // MARK: - buildTagMap

    @MainActor
    @Test func existingTagSkipped() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let existing = Tag(name: "开心", colorHex: "#FF0000")
        ctx.insert(existing)
        try ctx.save()

        let srcTag = Tag(name: "开心", colorHex: "#00FF00")  // same name, different color
        let dto = ExportService.TagDTO(srcTag)

        let (map, newCount) = ImportService.buildTagMap(
            dtos: [dto], existing: [existing], context: ctx)

        #expect(map["开心"] === existing)  // returns existing object, not new one
        #expect(newCount == 0)
        let tags = try ctx.fetch(FetchDescriptor<Tag>())
        #expect(tags.count == 1)  // no duplicate
    }

    @MainActor
    @Test func newTagInserted() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext

        let srcTag = Tag(name: "感恩", colorHex: "#D8A3C4")
        let dto = ExportService.TagDTO(srcTag)

        let (map, newCount) = ImportService.buildTagMap(
            dtos: [dto], existing: [], context: ctx)

        #expect(map["感恩"] != nil)
        #expect(newCount == 1)
        let tags = try ctx.fetch(FetchDescriptor<Tag>())
        #expect(tags.count == 1)
        #expect(tags[0].colorHex == "#D8A3C4")
    }
```

- [ ] **Step 2: 运行测试，确认 FAILED**

```bash
xcodebuild test -project Smile.xcodeproj -scheme SmileTests -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SmileTests/ImportServiceTests 2>&1 | grep -E "passed|failed"
```

- [ ] **Step 3: 用真实实现替换 buildTagMap stub**

```swift
    @MainActor
    static func buildTagMap(
        dtos: [ExportService.TagDTO],
        existing: [Tag],
        context: ModelContext
    ) -> ([String: Tag], Int) {
        var map: [String: Tag] = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.name, $0) })
        var newCount = 0

        for dto in dtos where map[dto.name] == nil {
            let t = Tag(name: dto.name, colorHex: dto.colorHex, createdAt: dto.createdAt)
            context.insert(t)
            map[dto.name] = t
            newCount += 1
        }
        return (map, newCount)
    }
```

- [ ] **Step 4: 运行测试，确认 PASSED**

```bash
xcodebuild test -project Smile.xcodeproj -scheme SmileTests -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SmileTests/ImportServiceTests 2>&1 | grep -E "passed|failed"
```

- [ ] **Step 5: Commit**

```bash
git add Smile/Core/Import/ImportService.swift SmileTests/ImportServiceTests.swift
git commit -m "feat: implement buildTagMap"
```

---

## Task 6: 实现 insertEntry 和 updateEntry

**Files:**
- Modify: `Smile/Core/Import/ImportService.swift`
- Modify: `SmileTests/ImportServiceTests.swift`

- [ ] **Step 1: 添加测试**

```swift
    // MARK: - insertEntry / updateEntry

    @MainActor
    @Test func insertEntryCreatesRecord() throws {
        let srcContainer = try ModelContainerFactory.makeInMemory()
        let srcCtx = srcContainer.mainContext
        ModelContainerFactory.seedIfNeeded(context: srcCtx)
        let groups = try srcCtx.fetch(FetchDescriptor<Group>())
        let builtIn = groups.first(where: \.isBuiltIn)!
        let tag = Tag(name: "开心", colorHex: "#FF0")
        srcCtx.insert(tag)
        let entry = Entry(id: UUID(), title: "测试标题", titleSource: .manual,
                          bodyText: "内容", group: builtIn)
        entry.tags = [tag]
        srcCtx.insert(entry)
        try srcCtx.save()
        let dto = ExportService.EntryDTO(entry)

        let dstContainer = try ModelContainerFactory.makeInMemory()
        let dstCtx = dstContainer.mainContext
        ModelContainerFactory.seedIfNeeded(context: dstCtx)
        let dstGroups = try dstCtx.fetch(FetchDescriptor<Group>())
        let dstBuiltIn = dstGroups.first(where: { $0.name == builtIn.name })!
        let dstTag = Tag(name: "开心", colorHex: "#FF0")
        dstCtx.insert(dstTag)

        // groupMap: DTO's builtIn.id → dstBuiltIn
        let groupMap: [UUID: Group] = [builtIn.id: dstBuiltIn]
        let tagMap: [String: Tag] = ["开心": dstTag]

        ImportService.insertEntry(from: dto, groupMap: groupMap,
                                  tagMap: tagMap, context: dstCtx)
        try dstCtx.save()

        let entries = try dstCtx.fetch(FetchDescriptor<Entry>())
        #expect(entries.count == 1)
        #expect(entries[0].id == entry.id)
        #expect(entries[0].title == "测试标��")
        #expect(entries[0].bodyText == "内容")
        #expect(entries[0].group?.id == dstBuiltIn.id)
        #expect(entries[0].tags.map(\.name) == ["开心"])
    }

    @MainActor
    @Test func updateEntryOverwritesWhenNewerAndSkipsWhenOlder() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let oldDate = Date(timeIntervalSince1970: 1000)
        let newDate = Date(timeIntervalSince1970: 2000)
        let entry = Entry(id: UUID(), title: "旧标题", bodyText: "旧内容",
                          updatedAt: oldDate)
        ctx.insert(entry)
        try ctx.save()

        // DTO with newer updatedAt
        let srcEntry = Entry(id: entry.id, title: "新标题", bodyText: "新内容",
                             updatedAt: newDate)
        let dto = ExportService.EntryDTO(srcEntry)

        ImportService.updateEntry(entry, from: dto, groupMap: [:],
                                  tagMap: [:], context: ctx)
        #expect(entry.title == "新标题")
        #expect(entry.bodyText == "新内容")
    }
```

- [ ] **Step 2: 运行测试，确认 FAILED（stub 实现）**

```bash
xcodebuild test -project Smile.xcodeproj -scheme SmileTests -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SmileTests/ImportServiceTests 2>&1 | grep -E "passed|failed"
```

- [ ] **Step 3: 实现 insertEntry**

将 `insertEntry` stub 替换为：

```swift
    @MainActor
    static func insertEntry(
        from dto: ExportService.EntryDTO,
        groupMap: [UUID: Group],
        tagMap: [String: Tag],
        context: ModelContext
    ) {
        let group: Group? = dto.groupID.flatMap { groupMap[$0] }
        let entry = Entry(
            id: dto.id,
            title: dto.title,
            titleSource: TitleSource(rawValue: dto.titleSource) ?? .auto,
            bodyText: dto.bodyText,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt,
            group: group
        )
        context.insert(entry)
        entry.tags = dto.tagNames.compactMap { tagMap[$0] }

        for attDTO in dto.attachments {
            let att = MediaAttachment(
                kind: MediaKind(rawValue: attDTO.kind) ?? .photo,
                relativePath: attDTO.relativePath,
                durationSeconds: attDTO.durationSeconds,
                transcript: attDTO.transcript,
                sortOrder: attDTO.sortOrder,
                entry: entry
            )
            context.insert(att)
        }
    }
```

- [ ] **Step 4: 实现 updateEntry**

将 `updateEntry` stub 替换为：

```swift
    @MainActor
    static func updateEntry(
        _ entry: Entry,
        from dto: ExportService.EntryDTO,
        groupMap: [UUID: Group],
        tagMap: [String: Tag],
        context: ModelContext
    ) {
        entry.title = dto.title
        entry.titleSourceRaw = dto.titleSource
        entry.bodyText = dto.bodyText
        entry.updatedAt = dto.updatedAt
        entry.group = dto.groupID.flatMap { groupMap[$0] }
        entry.tags = dto.tagNames.compactMap { tagMap[$0] }

        let oldAtts = entry.attachments
        for att in oldAtts { context.delete(att) }

        for attDTO in dto.attachments {
            let att = MediaAttachment(
                kind: MediaKind(rawValue: attDTO.kind) ?? .photo,
                relativePath: attDTO.relativePath,
                durationSeconds: attDTO.durationSeconds,
                transcript: attDTO.transcript,
                sortOrder: attDTO.sortOrder,
                entry: entry
            )
            context.insert(att)
        }
    }
```

- [ ] **Step 5: 运行测试，确认 PASSED**

```bash
xcodebuild test -project Smile.xcodeproj -scheme SmileTests -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SmileTests/ImportServiceTests 2>&1 | grep -E "passed|failed"
```

- [ ] **Step 6: Commit**

```bash
git add Smile/Core/Import/ImportService.swift SmileTests/ImportServiceTests.swift
git commit -m "feat: implement insertEntry and updateEntry"
```

---

## Task 7: 实现 copyMedia 和 replaceMedia

**Files:**
- Modify: `Smile/Core/Import/ImportService.swift`
- Modify: `SmileTests/ImportServiceTests.swift`

- [ ] **Step 1: 添加测试**

```swift
    // MARK: - Media helpers

    @Test func copyMediaCopiesDirectory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
        let mediaDir = tempRoot.appendingPathComponent("media-src-\(UUID())")
        let entryID = UUID()
        let srcDir = mediaDir.appendingPathComponent(entryID.uuidString)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try Data("img".utf8).write(to: srcDir.appendingPathComponent("photo.jpg"))

        let storeRoot = tempRoot.appendingPathComponent("store-\(UUID())")
        let store = MediaStore(rootURL: storeRoot)

        ImportService.copyMedia(entryID: entryID, from: mediaDir, mediaStore: store)

        let dstFile = store.absoluteURL(relativePath: "\(entryID.uuidString)/photo.jpg")
        #expect(FileManager.default.fileExists(atPath: dstFile.path))

        try? FileManager.default.removeItem(at: mediaDir)
        try? FileManager.default.removeItem(at: storeRoot)
    }

    @Test func replaceMediaDeletesOldAndCopiesNew() throws {
        let tempRoot = FileManager.default.temporaryDirectory
        let entryID = UUID()

        // Pre-existing file in store
        let storeRoot = tempRoot.appendingPathComponent("store-\(UUID())")
        let store = MediaStore(rootURL: storeRoot)
        let existingDir = store.directoryURL(for: entryID)
        try FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: existingDir.appendingPathComponent("old.jpg"))

        // New media from zip
        let mediaDir = tempRoot.appendingPathComponent("media-\(UUID())")
        let srcDir = mediaDir.appendingPathComponent(entryID.uuidString)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: srcDir.appendingPathComponent("new.jpg"))

        ImportService.replaceMedia(entryID: entryID, from: mediaDir, mediaStore: store)

        let oldFile = store.absoluteURL(relativePath: "\(entryID.uuidString)/old.jpg")
        let newFile = store.absoluteURL(relativePath: "\(entryID.uuidString)/new.jpg")
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: newFile.path))

        try? FileManager.default.removeItem(at: storeRoot)
        try? FileManager.default.removeItem(at: mediaDir)
    }
```

- [ ] **Step 2: 运行测试，确认 FAILED**

```bash
xcodebuild test -project Smile.xcodeproj -scheme SmileTests -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SmileTests/ImportServiceTests 2>&1 | grep -E "passed|failed"
```

- [ ] **Step 3: 实现 copyMedia 和 replaceMedia**

将两个 stub 替换为：

```swift
    static func copyMedia(entryID: UUID, from mediaDir: URL, mediaStore: MediaStore) {
        let src = mediaDir.appendingPathComponent(entryID.uuidString)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        let dst = mediaStore.directoryURL(for: entryID)
        guard !FileManager.default.fileExists(atPath: dst.path) else { return }
        try? FileManager.default.copyItem(at: src, to: dst)
    }

    static func replaceMedia(entryID: UUID, from mediaDir: URL, mediaStore: MediaStore) {
        let dst = mediaStore.directoryURL(for: entryID)
        if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: dst)
        }
        let src = mediaDir.appendingPathComponent(entryID.uuidString)
        if FileManager.default.fileExists(atPath: src.path) {
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }
```

- [ ] **Step 4: 运行所有 ImportService 测试，确认 PASSED**

```bash
xcodebuild test -project Smile.xcodeproj -scheme SmileTests -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SmileTests/ImportServiceTests 2>&1 | grep -E "passed|failed"
```

- [ ] **Step 5: Commit**

```bash
git add Smile/Core/Import/ImportService.swift SmileTests/ImportServiceTests.swift
git commit -m "feat: implement copyMedia and replaceMedia"
```

---

## Task 8: 整合测试（导出→导入全链路）

**Files:**
- Modify: `SmileTests/ImportServiceTests.swift`

- [ ] **Step 1: 添加集成测试**

```swift
    // MARK: - Integration

    @MainActor
    @Test func exportThenImportRoundTrip() throws {
        // ── 源设备：准备数据并导出 ──
        let srcContainer = try ModelContainerFactory.makeInMemory()
        let srcCtx = srcContainer.mainContext
        ModelContainerFactory.seedIfNeeded(context: srcCtx)
        let srcGroups = try srcCtx.fetch(FetchDescriptor<Group>())
        let srcBuiltIn = srcGroups.first(where: \.isBuiltIn)!

        let tag = Tag(name: "快乐", colorHex: "#FFCC00")
        srcCtx.insert(tag)
        let entry = Entry(id: UUID(), title: "美好的一天", bodyText: "今天很开心",
                          group: srcBuiltIn)
        entry.tags = [tag]
        srcCtx.insert(entry)
        try srcCtx.save()

        let srcStore = MediaStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("src-store-\(UUID())"))
        let zipURL = try ExportService.exportAll(context: srcCtx, mediaStore: srcStore)
        defer { try? FileManager.default.removeItem(at: zipURL) }
        defer { try? FileManager.default.removeItem(at: srcStore.rootURL) }

        // ── 目标设备：仅有内置分组，导入 ──
        let dstContainer = try ModelContainerFactory.makeInMemory()
        let dstCtx = dstContainer.mainContext
        ModelContainerFactory.seedIfNeeded(context: dstCtx)
        let dstStore = MediaStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("dst-store-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: dstStore.rootURL) }

        let result = try ImportService.importBackup(
            from: zipURL, context: dstCtx, mediaStore: dstStore)

        #expect(result.newEntries == 1)
        #expect(result.skippedEntries == 0)
        #expect(result.updatedEntries == 0)
        #expect(result.newTags == 1)

        let dstEntries = try dstCtx.fetch(FetchDescriptor<Entry>())
        #expect(dstEntries.count == 1)
        #expect(dstEntries[0].title == "美好的一天")
        #expect(dstEntries[0].group?.name == srcBuiltIn.name)
        #expect(dstEntries[0].tags.map(\.name) == ["快乐"])
    }

    @MainActor
    @Test func secondImportSkipsDuplicates() throws {
        let srcContainer = try ModelContainerFactory.makeInMemory()
        let srcCtx = srcContainer.mainContext
        ModelContainerFactory.seedIfNeeded(context: srcCtx)
        let entry = Entry(id: UUID(), title: "唯一", bodyText: "只有一条")
        srcCtx.insert(entry)
        try srcCtx.save()

        let srcStore = MediaStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("src2-\(UUID())"))
        let zipURL = try ExportService.exportAll(context: srcCtx, mediaStore: srcStore)
        defer { try? FileManager.default.removeItem(at: zipURL)
                try? FileManager.default.removeItem(at: srcStore.rootURL) }

        let dstContainer = try ModelContainerFactory.makeInMemory()
        let dstCtx = dstContainer.mainContext
        ModelContainerFactory.seedIfNeeded(context: dstCtx)
        let dstStore = MediaStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("dst2-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: dstStore.rootURL) }

        _ = try ImportService.importBackup(from: zipURL, context: dstCtx, mediaStore: dstStore)
        let result2 = try ImportService.importBackup(from: zipURL, context: dstCtx, mediaStore: dstStore)

        #expect(result2.newEntries == 0)
        #expect(result2.skippedEntries == 1)
        let entries = try dstCtx.fetch(FetchDescriptor<Entry>())
        #expect(entries.count == 1)  // no duplicate
    }
```

- [ ] **Step 2: 运行集成测试**

```bash
xcodebuild test -project Smile.xcodeproj -scheme SmileTests -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SmileTests/ImportServiceTests 2>&1 | grep -E "passed|failed"
```

Expected: 全部 PASSED

- [ ] **Step 3: Commit**

```bash
git add SmileTests/ImportServiceTests.swift
git commit -m "test: add ImportService integration tests"
```

---

## Task 9: SettingsView 增加导入 UI

**Files:**
- Modify: `Smile/Features/Settings/SettingsView.swift`

- [ ] **Step 1: 将 SettingsView 全文替换为带导入功能的版本**

```swift
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context

    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var exportError: String?

    @State private var showFilePicker = false
    @State private var importing = false
    @State private var importResult: ImportService.ImportResult?
    @State private var importError: String?

    var body: some View {
        Form {
            Section("功能") {
                NavigationLink("AI 自动标题") { AISettingsView() }
            }
            Section("数据") {
                Button {
                    Task { await exportAll() }
                } label: {
                    HStack {
                        Label("导出全部记录", systemImage: "square.and.arrow.up")
                        Spacer()
                        if exporting { ProgressView() }
                    }
                }
                .disabled(exporting || importing)

                Button {
                    showFilePicker = true
                } label: {
                    HStack {
                        Label("导入备份", systemImage: "square.and.arrow.down")
                        Spacer()
                        if importing { ProgressView() }
                    }
                }
                .disabled(importing || exporting)
            }
            Section("关于") {
                LabeledContent("版本") { Text("1.0") }
            }
        }
        .navigationTitle("设置")
        .sheet(item: Binding<ExportFileWrapper?>(
            get: { exportURL.map { ExportFileWrapper(url: $0) } },
            set: { _ in exportURL = nil }
        )) { w in
            ShareSheetForURL(url: w.url)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType.zip]
        ) { result in
            handleFilePicked(result)
        }
        .alert("导出失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .alert("导入完成", isPresented: Binding(
            get: { importResult != nil },
            set: { if !$0 { importResult = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            if let r = importResult {
                Text("新增 \(r.newEntries) 条记录（更新 \(r.updatedEntries) 条）、\(r.newGroups) 个分组、\(r.newTags) 个标签，跳过 \(r.skippedEntries) 条已有记录")
            }
        }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Export

    @MainActor
    private func exportAll() async {
        exporting = true
        defer { exporting = false }
        do {
            exportURL = try ExportService.exportAll(
                context: context, mediaStore: .production())
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Import

    private func handleFilePicked(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                importError = "无法读取所选文件：\(error.localizedDescription)"
                return
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
            Task { await doImport(from: tempURL) }
        }
    }

    @MainActor
    private func doImport(from url: URL) async {
        importing = true
        defer {
            importing = false
            try? FileManager.default.removeItem(at: url)
        }
        do {
            importResult = try ImportService.importBackup(
                from: url, context: context, mediaStore: .production())
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct ExportFileWrapper: Identifiable {
    let id = UUID(); let url: URL
}

private struct ShareSheetForURL: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
```

- [ ] **Step 2: 编译验证**

```bash
xcodebuild build -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 16' -quiet
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Smile/Features/Settings/SettingsView.swift
git commit -m "feat: add import backup UI to SettingsView"
```

---

## Task 10: 运行全套测试

- [ ] **Step 1: 运行所有测试**

```bash
xcodebuild test -project Smile.xcodeproj -scheme SmileTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "Test Suite|passed|failed|error:" | tail -30
```

Expected: 全部测试通过，无 FAILED

- [ ] **Step 2: 如有测试失败，修复后重跑**

- [ ] **Step 3: 最终 commit（如有修复）**

```bash
git add -A
git commit -m "fix: resolve failing tests after import feature"
```
