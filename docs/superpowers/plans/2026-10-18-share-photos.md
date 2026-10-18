# 相册分享照片新建记录 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在系统「照片」App 中选中 1~9 张照片 → 分享 → 微笑储蓄罐，App 自动新建一条记录并进入编辑状态。

**Architecture:** 新增 Share Extension `SmileShare`，把照片原始文件写入 App Group 共享容器里的收件箱（`SharedInbox`，先写 `.tmp-<id>` 再原子重命名），随后通过 `smilejar://share` 唤起主 App。主 App 的 `ShareInboxCenter`（`@Observable`）负责解码收件箱、记录当前是否有编辑器打开；`RootView` 在没有编辑器时打开带图的新编辑器，已有编辑器时由编辑器自己弹窗询问。spec：`docs/superpowers/specs/2026-10-18-share-photos-design.md`。

**Tech Stack:** SwiftUI, SwiftData, UIKit（扩展）, App Groups, XcodeGen, Swift Testing, iOS 17+

**环境前提：** 所有构建/测试命令需在 macOS + Xcode 26+ 上执行。工程由 XcodeGen 生成，**每次新增/删除源文件或修改 `project.yml` 后都要先运行 `xcodegen generate`**。`docs/` 与 `*.xcodeproj/` 在 `.gitignore` 中，但 `project.pbxproj` 与 specs/plans 已被跟踪：新文件需 `git add -f`。

---

## 文件清单

| 操作 | 路径 | 职责 |
|------|------|------|
| 新增 | `Smile/Core/SharedInbox/SharedInbox.swift` | 收件箱目录读写（主 App 与扩展共用，仅依赖 Foundation） |
| 新增 | `Smile/Core/SharedInbox/ShareInboxCenter.swift` | 主 App：解码 batch、待处理图片、编辑器打开计数 |
| 新增 | `SmileTests/SharedInboxTests.swift` | SharedInbox 单测 |
| 新增 | `SmileTests/ShareInboxCenterTests.swift` | ShareInboxCenter 单测 |
| 新增 | `SmileShare/ShareViewController.swift` | 扩展：收集照片 → 写收件箱 → 唤起主 App |
| 新增 | `SmileShare/SmileShare.entitlements` | 扩展 App Group |
| 生成 | `SmileShare/Info.plist` | 由 XcodeGen 按 `project.yml` 生成 |
| 修改 | `project.yml` | 扩展 target、主 App 嵌入扩展、URL scheme |
| 修改 | `Smile/Smile.entitlements` | 主 App App Group |
| 生成 | `Smile/Info.plist` | 由 XcodeGen 重新生成（新增 `CFBundleURLTypes`） |
| 修改 | `Smile/SmileApp.swift` | 注入 `ShareInboxCenter` |
| 修改 | `Smile/Features/EntryEditor/iOSNoteEditorView.swift` | `initialImages`、计数登记、收图弹窗、冷启动补选分组 |
| 修改 | `Smile/App/RootView.swift` | `smilejar://share`、前台检查、打开带图编辑器 |
| 修改 | `README.md` | 特性说明 |

---

## Task 1: SharedInbox（收件箱）

**Files:**
- Create: `Smile/Core/SharedInbox/SharedInbox.swift`
- Test: `SmileTests/SharedInboxTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `SmileTests/SharedInboxTests.swift`：

```swift
import Testing
import Foundation
@testable import Smile

@Suite("SharedInbox")
struct SharedInboxTests {
    func makeInbox() -> SharedInbox {
        SharedInbox(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedInboxTest_\(UUID().uuidString)"))
    }

    @Test func emptyRootHasNoBatches() {
        #expect(makeInbox().pendingBatches().isEmpty)
    }

    @Test func committedBatchIsListed() throws {
        let inbox = makeInbox()
        let pending = try inbox.beginBatch()
        try pending.addData(Data("a".utf8), ext: "jpg", index: 1)
        let batch = try inbox.commit(pending)

        let batches = inbox.pendingBatches()
        #expect(batches.map(\.id) == [batch.id])
        #expect(inbox.fileURLs(in: batch).count == 1)
    }

    @Test func uncommittedBatchIsHidden() throws {
        let inbox = makeInbox()
        let pending = try inbox.beginBatch()
        try pending.addData(Data("a".utf8), ext: "jpg", index: 1)

        #expect(inbox.pendingBatches().isEmpty)
    }

    @Test func discardRemovesTemporaryDirectory() throws {
        let inbox = makeInbox()
        let pending = try inbox.beginBatch()
        inbox.discard(pending)

        #expect(!FileManager.default.fileExists(atPath: pending.url.path))
    }

    @Test func batchesSortedByCreationDate() throws {
        let inbox = makeInbox()
        let first = try inbox.commit(try inbox.beginBatch())
        let second = try inbox.commit(try inbox.beginBatch())
        // 人为把 second 设为更早创建
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -100)],
                                              ofItemAtPath: second.url.path)
        try FileManager.default.setAttributes([.creationDate: Date()],
                                              ofItemAtPath: first.url.path)

        #expect(inbox.pendingBatches().map(\.id) == [second.id, first.id])
    }

    @Test func fileURLsSortedByIndex() throws {
        let inbox = makeInbox()
        let pending = try inbox.beginBatch()
        try pending.addData(Data("b".utf8), ext: "jpg", index: 2)
        try pending.addData(Data("c".utf8), ext: "png", index: 10)
        try pending.addData(Data("a".utf8), ext: "heic", index: 1)
        let batch = try inbox.commit(pending)

        #expect(inbox.fileURLs(in: batch).map(\.lastPathComponent) == ["0001.heic", "0002.jpg", "0010.png"])
    }

    @Test func addFileCopiesSourceWithLowercasedExtension() throws {
        let inbox = makeInbox()
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src_\(UUID().uuidString).HEIC")
        try Data("img".utf8).write(to: src)
        let pending = try inbox.beginBatch()
        try pending.addFile(from: src, index: 1)
        let batch = try inbox.commit(pending)

        let files = inbox.fileURLs(in: batch)
        #expect(files.map(\.lastPathComponent) == ["0001.heic"])
        #expect(try Data(contentsOf: files[0]) == Data("img".utf8))
        #expect(FileManager.default.fileExists(atPath: src.path))
    }

    @Test func removeDeletesBatch() throws {
        let inbox = makeInbox()
        let batch = try inbox.commit(try inbox.beginBatch())
        inbox.remove(batch)

        #expect(inbox.pendingBatches().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: batch.url.path))
    }

    @Test func purgeRemovesOnlyStaleTemporaries() throws {
        let inbox = makeInbox()
        let staleTemp = try inbox.beginBatch()
        let committed = try inbox.commit(try inbox.beginBatch())

        inbox.purgeStaleTemporaries(olderThan: 3600, now: Date(timeIntervalSinceNow: 7200))

        #expect(!FileManager.default.fileExists(atPath: staleTemp.url.path))
        #expect(inbox.pendingBatches().map(\.id) == [committed.id])
    }

    @Test func purgeKeepsFreshTemporaries() throws {
        let inbox = makeInbox()
        let freshTemp = try inbox.beginBatch()

        inbox.purgeStaleTemporaries(olderThan: 3600, now: Date())

        #expect(FileManager.default.fileExists(atPath: freshTemp.url.path))
    }
}
```

- [ ] **Step 2: 生成工程并运行测试，确认失败**

```bash
xcodegen generate
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SmileTests/SharedInboxTests test
```
Expected: 编译失败，`cannot find 'SharedInbox' in scope`。

- [ ] **Step 3: 实现 SharedInbox**

> 注：代码 review 后最终实现有调整（读不到创建时间时不清理、排序加 uuid 次序、扩展名统一在 `filename` 中规范化），以仓库中 `Smile/Core/SharedInbox/SharedInbox.swift` 为准。

创建 `Smile/Core/SharedInbox/SharedInbox.swift`：

```swift
import Foundation

/// 主 App 与分享扩展之间的照片收件箱，位于 App Group 共享容器 `ShareInbox/` 下。
/// 每次分享是一个 batch 目录：扩展先写入 `.tmp-<uuid>/`，写完后整体重命名为 `<uuid>/`，
/// 因此主 App 永远读不到写了一半的 batch。
/// 本文件同时编译进 Smile 与 SmileShare 两个 target，只能依赖 Foundation。
struct SharedInbox {
    static let appGroupID = "group.com.chuzhanfeng.smile.pic"
    static let tempPrefix = ".tmp-"

    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// App Group 容器不可用（签名/entitlements 配置错误）时返回 nil
    static func production() -> SharedInbox? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        return SharedInbox(rootURL: container.appendingPathComponent("ShareInbox"))
    }

    struct Batch: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let createdAt: Date
    }

    /// 尚未提交的 batch（扩展写入中）
    struct PendingBatch {
        let id: UUID
        let url: URL

        /// 复制源文件；index 从 1 开始，决定排序
        func addFile(from source: URL, index: Int) throws {
            let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
            try FileManager.default.copyItem(at: source, to: url.appendingPathComponent(Self.filename(index: index, ext: ext)))
        }

        func addData(_ data: Data, ext: String, index: Int) throws {
            try data.write(to: url.appendingPathComponent(Self.filename(index: index, ext: ext)), options: .atomic)
        }

        static func filename(index: Int, ext: String) -> String {
            String(format: "%04d", index) + "." + ext
        }
    }

    func beginBatch() throws -> PendingBatch {
        let id = UUID()
        let url = rootURL.appendingPathComponent(Self.tempPrefix + id.uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return PendingBatch(id: id, url: url)
    }

    @discardableResult
    func commit(_ pending: PendingBatch) throws -> Batch {
        let dest = rootURL.appendingPathComponent(pending.id.uuidString)
        try FileManager.default.moveItem(at: pending.url, to: dest)
        return Batch(id: pending.id, url: dest, createdAt: Self.creationDate(of: dest))
    }

    func discard(_ pending: PendingBatch) {
        try? FileManager.default.removeItem(at: pending.url)
    }

    /// 已提交的 batch，最早的在前。`.tmp-*` 目录因名字不是 UUID 被自然过滤。
    func pendingBatches() -> [Batch] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url -> Batch? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return Batch(id: id, url: url, createdAt: Self.creationDate(of: url))
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func fileURLs(in batch: Batch) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: batch.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func remove(_ batch: Batch) {
        try? FileManager.default.removeItem(at: batch.url)
    }

    /// 清理扩展崩溃/被系统杀掉后遗留的临时目录
    func purgeStaleTemporaries(olderThan age: TimeInterval = 3600, now: Date = .now) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent.hasPrefix(Self.tempPrefix) {
            if now.timeIntervalSince(Self.creationDate(of: url)) > age {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func creationDate(of url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] as? Date) ?? .distantPast
    }
}
```

- [ ] **Step 4: 重新生成并运行测试，确认通过**

```bash
xcodegen generate
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SmileTests/SharedInboxTests test
```
Expected: `** TEST SUCCEEDED **`，10 个测试全部通过。

- [ ] **Step 5: 提交**

```bash
git add Smile/Core/SharedInbox/SharedInbox.swift SmileTests/SharedInboxTests.swift
git add -f Smile.xcodeproj/project.pbxproj
git commit -m "feat: 新增 SharedInbox 分享收件箱"
```

---

## Task 2: ShareInboxCenter（主 App 协调状态）

> 注（最终实现）：中心不再解码图片，只把 batch 认领到 `tmp/ShareProcessing/<batchID>/` 并用 ImageIO 轻量校验，持有 `incomingPhotoURLs: [URL]?`；`takeIncoming() -> (urls:, failures:)` 交出文件所有权，编辑器逐张全分辨率解码并存为 JPEG 0.9（与相册选择器一致），下文的 `incomingImages` / 4096 降采样已被替换。

**Files:**
- Create: `Smile/Core/SharedInbox/ShareInboxCenter.swift`
- Test: `SmileTests/ShareInboxCenterTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `SmileTests/ShareInboxCenterTests.swift`：

```swift
import Testing
import Foundation
import UIKit
@testable import Smile

@Suite("ShareInboxCenter")
@MainActor
struct ShareInboxCenterTests {
    func makeInbox() -> SharedInbox {
        SharedInbox(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareInboxCenterTest_\(UUID().uuidString)"))
    }

    func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// 写入并提交一个 batch；`good` 张有效 PNG + `bad` 个无法解码的文件
    @discardableResult
    func commitBatch(_ inbox: SharedInbox, good: Int, bad: Int = 0) throws -> SharedInbox.Batch {
        let pending = try inbox.beginBatch()
        var index = 1
        for _ in 0..<good { try pending.addData(pngData(), ext: "png", index: index); index += 1 }
        for _ in 0..<bad { try pending.addData(Data("not an image".utf8), ext: "jpg", index: index); index += 1 }
        return try inbox.commit(pending)
    }

    @Test func pullDecodesImagesAndRemovesBatch() throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 3)
        let center = ShareInboxCenter(inbox: inbox)

        #expect(center.pullNextBatch() == true)
        #expect(center.incomingImages?.count == 3)
        #expect(center.lastDecodeFailures == 0)
        #expect(inbox.pendingBatches().isEmpty)
    }

    @Test func pullSkipsUndecodableFiles() throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 1, bad: 1)
        let center = ShareInboxCenter(inbox: inbox)

        #expect(center.pullNextBatch() == true)
        #expect(center.incomingImages?.count == 1)
        #expect(center.lastDecodeFailures == 1)
    }

    @Test func pullWithAllFilesBrokenReturnsFalse() throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 0, bad: 2)
        let center = ShareInboxCenter(inbox: inbox)

        #expect(center.pullNextBatch() == false)
        #expect(center.incomingImages == nil)
        #expect(center.lastDecodeFailures == 2)
        #expect(inbox.pendingBatches().isEmpty)
    }

    @Test func pullDoesNotOverwriteExistingIncoming() throws {
        let inbox = makeInbox()
        let first = try commitBatch(inbox, good: 1)
        let second = try commitBatch(inbox, good: 2)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -100)],
                                              ofItemAtPath: first.url.path)
        try FileManager.default.setAttributes([.creationDate: Date()],
                                              ofItemAtPath: second.url.path)
        let center = ShareInboxCenter(inbox: inbox)

        #expect(center.pullNextBatch() == true)
        #expect(center.pullNextBatch() == false)
        #expect(center.incomingImages?.count == 1)
        #expect(inbox.pendingBatches().map(\.id) == [second.id])
    }

    @Test func pullWithEmptyInboxReturnsFalse() {
        let center = ShareInboxCenter(inbox: makeInbox())
        #expect(center.pullNextBatch() == false)
        #expect(center.incomingImages == nil)
    }

    @Test func pullWithoutInboxReturnsFalse() {
        let center = ShareInboxCenter(inbox: nil)
        #expect(center.pullNextBatch() == false)
    }

    @Test func takeIncomingReturnsAndClearsState() throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 2, bad: 1)
        let center = ShareInboxCenter(inbox: inbox)
        center.pullNextBatch()

        let taken = center.takeIncoming()

        #expect(taken.images.count == 2)
        #expect(taken.failures == 1)
        #expect(center.incomingImages == nil)
        #expect(center.lastDecodeFailures == 0)
    }

    @Test func discardIncomingClearsState() throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 1)
        let center = ShareInboxCenter(inbox: inbox)
        center.pullNextBatch()

        center.discardIncoming()

        #expect(center.incomingImages == nil)
    }

    @Test func editorCountTracksAppearAndNeverGoesNegative() {
        let center = ShareInboxCenter(inbox: nil)
        center.editorDidAppear()
        #expect(center.openEditorCount == 1)
        center.editorDidDisappear()
        center.editorDidDisappear()
        #expect(center.openEditorCount == 0)
    }
}
```

- [ ] **Step 2: 生成工程并运行测试，确认失败**

```bash
xcodegen generate
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SmileTests/ShareInboxCenterTests test
```
Expected: 编译失败，`cannot find 'ShareInboxCenter' in scope`。

- [ ] **Step 3: 实现 ShareInboxCenter**

> 注：代码 review 后最终 API 有调整，以仓库中 `Smile/Core/SharedInbox/ShareInboxCenter.swift` 为准：`pullNextBatch() async -> PullResult`（`.nothing` / `.ready(count:)` / `.allFailed(failures:)`，后台只做 ImageIO 文件头校验、不解码像素）；`incomingImages` 改为 `incomingPhotoURLs: [URL]?`，`lastDecodeFailures` 改为 `incomingFailures`（只在 `incomingPhotoURLs != nil` 时有意义）；`takeIncoming() -> (urls:, failures:)` 交出文件所有权，处理完调用 `finishHandOff(of:)`；照片由编辑器逐张全分辨率存为 JPEG 0.9（不再降采样到 4096）。`discardIncoming()` / `openEditorCount` 不变。

创建 `Smile/Core/SharedInbox/ShareInboxCenter.swift`：

```swift
import UIKit
import Observation

/// 主 App 内协调「从相册分享进来的照片」：
/// - 从 SharedInbox 取出最早的 batch 并解码为 `incomingImages`
/// - 记录当前打开的编辑器数量，供 RootView 决定是新开编辑器还是交给已打开的编辑器弹窗
@Observable
@MainActor
final class ShareInboxCenter {
    private let inbox: SharedInbox?

    private(set) var openEditorCount = 0
    /// 已解码、等待交给编辑器的一批照片
    private(set) var incomingImages: [UIImage]?
    private(set) var lastDecodeFailures = 0

    init(inbox: SharedInbox? = SharedInbox.production()) {
        self.inbox = inbox
    }

    func editorDidAppear() { openEditorCount += 1 }
    func editorDidDisappear() { openEditorCount = max(0, openEditorCount - 1) }

    /// 没有待处理图片时，取最早的 batch 解码并删除它。
    /// 返回是否得到了至少一张图片；全部解码失败时返回 false，失败数见 `lastDecodeFailures`。
    @discardableResult
    func pullNextBatch() -> Bool {
        guard incomingImages == nil, let inbox, let batch = inbox.pendingBatches().first else { return false }
        var images: [UIImage] = []
        var failures = 0
        for url in inbox.fileURLs(in: batch) {
            if let image = UIImage(contentsOfFile: url.path) {
                images.append(image)
            } else {
                failures += 1
            }
        }
        inbox.remove(batch)
        lastDecodeFailures = failures
        guard !images.isEmpty else { return false }
        incomingImages = images
        return true
    }

    func takeIncoming() -> (images: [UIImage], failures: Int) {
        let result = (images: incomingImages ?? [], failures: lastDecodeFailures)
        incomingImages = nil
        lastDecodeFailures = 0
        return result
    }

    func discardIncoming() {
        _ = takeIncoming()
    }

    func purgeStaleTemporaries() {
        inbox?.purgeStaleTemporaries()
    }
}
```

- [ ] **Step 4: 重新生成并运行测试，确认通过**

```bash
xcodegen generate
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SmileTests/ShareInboxCenterTests test
```
Expected: `** TEST SUCCEEDED **`，9 个测试全部通过。

- [ ] **Step 5: 提交**

```bash
git add Smile/Core/SharedInbox/ShareInboxCenter.swift SmileTests/ShareInboxCenterTests.swift
git add -f Smile.xcodeproj/project.pbxproj
git commit -m "feat: 新增 ShareInboxCenter 协调分享照片"
```

---

## Task 3: 主 App 的 App Group 与 URL scheme

**Files:**
- Modify: `Smile/Smile.entitlements`
- Modify: `project.yml`（`targets.Smile.info.properties`）
- Regenerated: `Smile/Info.plist`

- [ ] **Step 1: 主 App entitlements 加入 App Group**

把 `Smile/Smile.entitlements` 全文替换为：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.chuzhanfeng.smile.pic</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: project.yml 注册 URL scheme**

在 `project.yml` 的 `targets.Smile.info.properties` 中，`CFBundleDocumentTypes:` 这一行之前插入：

```yaml
        CFBundleURLTypes:
          - CFBundleURLName: com.chuzhanfeng.smile
            CFBundleURLSchemes:
              - smilejar
```

- [ ] **Step 3: 重新生成并检查 Info.plist**

```bash
xcodegen generate
grep -A6 CFBundleURLTypes Smile/Info.plist
```
Expected: 输出包含 `<string>smilejar</string>`。

- [ ] **Step 4: 编译确认无误**

```bash
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 提交**

```bash
git add Smile/Smile.entitlements project.yml Smile/Info.plist
git add -f Smile.xcodeproj/project.pbxproj
git commit -m "feat: 主 App 加入 App Group 与 smilejar URL scheme"
```

---

## Task 4: Share Extension `SmileShare`

**Files:**
- Create: `SmileShare/ShareViewController.swift`
- Create: `SmileShare/SmileShare.entitlements`
- Modify: `project.yml`（新增 target，主 App 依赖它）
- Generated: `SmileShare/Info.plist`

- [ ] **Step 1: 扩展 entitlements**

创建 `SmileShare/SmileShare.entitlements`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.chuzhanfeng.smile.pic</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: 扩展主逻辑**

创建 `SmileShare/ShareViewController.swift`：

```swift
import UIKit
import UniformTypeIdentifiers

/// 系统分享面板中的「微笑储蓄罐」：把照片原样复制进 App Group 收件箱，然后唤起主 App 进入编辑。
/// 只复制文件、不解码图片，避免触碰扩展约 120MB 的内存上限。
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    private let okButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        Task { await handleShare() }
    }

    // MARK: - Flow

    @MainActor
    private func handleShare() async {
        guard let inbox = SharedInbox.production(),
              let pending = try? inbox.beginBatch() else {
            showMessage("无法保存照片，请稍后重试", autoCancel: true)
            return
        }

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }

        var saved = 0
        for provider in providers {
            if await Self.store(provider, into: pending, index: saved + 1) { saved += 1 }
        }

        guard saved > 0 else {
            inbox.discard(pending)
            showMessage("没有可用的照片", autoCancel: true)
            return
        }
        guard (try? inbox.commit(pending)) != nil else {
            inbox.discard(pending)
            showMessage("无法保存照片，请稍后重试", autoCancel: true)
            return
        }

        if await openMainApp() {
            finish()
        } else {
            showMessage("已收到 \(saved) 张照片，请打开微笑储蓄罐继续编辑", autoCancel: false)
        }
    }

    /// 依次尝试：原始文件 → 原始数据 → UIImage 转 JPEG
    private static func store(_ provider: NSItemProvider, into batch: SharedInbox.PendingBatch, index: Int) async -> Bool {
        let imageType = UTType.image.identifier

        let copied: Bool = await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: imageType) { url, _ in
                // url 指向的临时文件在回调返回后即被删除，必须在回调内复制
                guard let url else { cont.resume(returning: false); return }
                cont.resume(returning: (try? batch.addFile(from: url, index: index)) != nil)
            }
        }
        if copied { return true }

        let data: Data? = await withCheckedContinuation { cont in
            _ = provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                cont.resume(returning: data)
            }
        }
        if let data, (try? batch.addData(data, ext: preferredExtension(of: provider), index: index)) != nil {
            return true
        }

        let jpeg: Data? = await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                cont.resume(returning: (object as? UIImage)?.jpegData(compressionQuality: 0.9))
            }
        }
        if let jpeg, (try? batch.addData(jpeg, ext: "jpg", index: index)) != nil {
            return true
        }
        return false
    }

    private static func preferredExtension(of provider: NSItemProvider) -> String {
        for id in provider.registeredTypeIdentifiers {
            if let type = UTType(id), type.conforms(to: .image), let ext = type.preferredFilenameExtension {
                return ext
            }
        }
        return "jpg"
    }

    /// 扩展没有官方 API 打开宿主 App，这里沿 responder chain 找到 UIApplication 调用 open。
    /// 若未来 iOS 封禁此方式会返回 false，由主 App 的前台检查兜底。
    @MainActor
    private func openMainApp() async -> Bool {
        guard let url = URL(string: "smilejar://share") else { return false }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await withCheckedContinuation { cont in
                    application.open(url, options: [:]) { cont.resume(returning: $0) }
                }
            }
            responder = current.next
        }
        return false
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)

        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 14
        card.translatesAutoresizingMaskIntoConstraints = false

        spinner.startAnimating()

        messageLabel.text = "正在发送到微笑储蓄罐…"
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        okButton.setTitle("好的", for: .normal)
        okButton.isHidden = true
        okButton.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, messageLabel, okButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 260),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
    }

    private func showMessage(_ text: String, autoCancel: Bool) {
        spinner.stopAnimating()
        spinner.isHidden = true
        messageLabel.text = text
        if autoCancel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.cancel() }
        } else {
            okButton.isHidden = false
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "SmileShare", code: 0))
    }
}
```

- [ ] **Step 3: project.yml 新增扩展 target**

在 `project.yml` 的 `targets:` 下、`SmileTests:` 之前插入：

```yaml
  SmileShare:
    type: app-extension
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: SmileShare
        excludes: [Info.plist, SmileShare.entitlements]
      - path: Smile/Core/SharedInbox/SharedInbox.swift
    settings:
      groups: [iphoneOnly]
      base:
        CODE_SIGN_ENTITLEMENTS: SmileShare/SmileShare.entitlements
        PRODUCT_BUNDLE_IDENTIFIER: com.chuzhanfeng.smile.pic
    info:
      path: SmileShare/Info.plist
      properties:
        CFBundleDisplayName: 微笑储蓄罐
        CFBundleShortVersionString: "1.0.6"
        CFBundleVersion: "6"
        NSExtension:
          NSExtensionPointIdentifier: com.apple.share-services
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ShareViewController
          NSExtensionAttributes:
            NSExtensionActivationRule:
              NSExtensionActivationSupportsImageWithMaxCount: 9
```

并在 `targets.Smile.dependencies` 中（`- package: ZIPFoundation` 之前）加入：

```yaml
      - target: SmileShare
```

> 注：扩展的 `CFBundleShortVersionString` / `CFBundleVersion` 必须与主 App 一致，以后每次发版两处一起改。

- [ ] **Step 4: 生成并编译**

```bash
xcodegen generate
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `** BUILD SUCCEEDED **`；`SmileShare/Info.plist` 已生成并包含 `NSExtensionActivationSupportsImageWithMaxCount`。

若报 `'open(_:options:completionHandler:)' is unavailable in application extensions`：把 `openMainApp()` 中的 `application.open(...)` 一段替换为下面的 selector 调用（行为相同，绕过编译期可用性检查）：

```swift
                let selector = NSSelectorFromString("openURL:options:completionHandler:")
                guard application.responds(to: selector) else { return false }
                typealias OpenFn = @convention(c) (AnyObject, Selector, URL, NSDictionary, Any?) -> Void
                let fn = unsafeBitCast(application.method(for: selector), to: OpenFn.self)
                fn(application, selector, url, NSDictionary(), nil)
                return true
```

- [ ] **Step 5: 跑一遍全部测试，确认没有回归**

```bash
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: 提交**

```bash
git add SmileShare/ShareViewController.swift SmileShare/SmileShare.entitlements SmileShare/Info.plist project.yml
git add -f Smile.xcodeproj/project.pbxproj
git commit -m "feat: 新增 SmileShare 分享扩展"
```

---

## Task 5: 注入 ShareInboxCenter 并改造编辑器

**Files:**
- Modify: `Smile/SmileApp.swift`
- Modify: `Smile/Features/EntryEditor/iOSNoteEditorView.swift`

- [ ] **Step 1: SmileApp 注入环境对象**

`Smile/SmileApp.swift` 中：

```swift
    @State private var lockSession = LockSessionManager()
```
下面加一行：
```swift
    @State private var shareCenter = ShareInboxCenter()
```

把
```swift
            RootView()
                .environment(lockSession)
```
改为
```swift
            RootView()
                .environment(lockSession)
                .environment(shareCenter)
```

- [ ] **Step 2: 编辑器新增环境对象、参数与状态**

`iOSNoteEditorView.swift` 顶部：

```swift
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
```
下面加：
```swift
    @Environment(ShareInboxCenter.self) private var shareCenter
```

把属性与 init：
```swift
    let editingEntryID: PersistentIdentifier?
    let initialGroupID: PersistentIdentifier?
    let onSaved: ((UUID, UUID) -> Void)?

    init(editingEntryID: PersistentIdentifier? = nil, initialGroupID: PersistentIdentifier? = nil, onSaved: ((UUID, UUID) -> Void)? = nil) {
        self.editingEntryID = editingEntryID
        self.initialGroupID = initialGroupID
        self.onSaved = onSaved
    }
```
替换为：
```swift
    let editingEntryID: PersistentIdentifier?
    let initialGroupID: PersistentIdentifier?
    /// 从相册分享进来的照片，打开后自动插入
    let initialImages: [UIImage]
    /// 分享照片中解码失败的数量，> 0 时提示
    let initialImageFailures: Int
    let onSaved: ((UUID, UUID) -> Void)?

    init(editingEntryID: PersistentIdentifier? = nil,
         initialGroupID: PersistentIdentifier? = nil,
         initialImages: [UIImage] = [],
         initialImageFailures: Int = 0,
         onSaved: ((UUID, UUID) -> Void)? = nil) {
        self.editingEntryID = editingEntryID
        self.initialGroupID = initialGroupID
        self.initialImages = initialImages
        self.initialImageFailures = initialImageFailures
        self.onSaved = onSaved
    }
```

在 `@State private var recordingPulse = false` 下加：
```swift
    @State private var showShareChoice = false
```

- [ ] **Step 3: onAppear / onDisappear 登记并插入初始照片**

把：
```swift
        .onAppear {
            initialize()
            if editingEntryID == nil {
```
替换为：
```swift
        .onAppear {
            shareCenter.editorDidAppear()
            initialize()
            if !initialImages.isEmpty {
                let images = initialImages
                let failures = initialImageFailures
                Task {
                    await insertPhotos(images)
                    if failures > 0 { showInsertPhotoError = true }
                }
            }
            if shareCenter.incomingImages != nil { showShareChoice = true }
            if editingEntryID == nil {
```

在 `.onDisappear { ... }` 闭包中，`thumbnails.removeAll()` 之后加一行：
```swift
            shareCenter.editorDidDisappear()
```

- [ ] **Step 4: 收图弹窗与冷启动补选分组**

在 `.onChange(of: model.autoSaveSignal) { ... }` 之前插入：

```swift
        .onChange(of: shareCenter.incomingImages != nil) { _, hasIncoming in
            if hasIncoming { showShareChoice = true }
        }
        .onChange(of: allGroups.count) { _, _ in
            // 冷启动时内置分组可能晚于编辑器出现才 seed 完成
            if model.selectedGroupID == nil {
                model.selectDefaultGroup(from: allGroups, initialGroupID: initialGroupID)
            }
        }
        .alert("收到 \(shareCenter.incomingImages?.count ?? 0) 张照片", isPresented: $showShareChoice) {
            Button("插入当前记录") { insertSharedPhotos() }
            Button("新建记录") { Task { await startNewEntryFromShare() } }
            Button("取消", role: .cancel) { shareCenter.discardIncoming() }
        } message: {
            Text("加入正在编辑的这条记录，还是新建一条记录？")
        }
```

- [ ] **Step 5: 新增两个辅助方法**

在 `private func removePhoto(_ draft: DraftAttachment)` 之前插入：

```swift
    private func insertSharedPhotos() {
        let incoming = shareCenter.takeIncoming()
        Task {
            await insertPhotos(incoming.images)
            if incoming.failures > 0 { showInsertPhotoError = true }
        }
    }

    /// incomingImages 保留在 shareCenter 中，本编辑器关闭后由 RootView 用它新建记录
    @MainActor
    private func startNewEntryFromShare() async {
        if canSave { await save() } else { dismiss() }
    }
```

- [ ] **Step 6: 修正 Preview**

文件末尾 `#Preview` 中，`.environment(\.modelContext, ...)` 之后追加：
```swift
    .environment(ShareInboxCenter(inbox: nil))
```

- [ ] **Step 7: 编译并跑全部测试**

```bash
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `** TEST SUCCEEDED **`（GroupDetailView / EntryDetailView 的调用点使用默认参数，无需修改）。

- [ ] **Step 8: 提交**

```bash
git add Smile/SmileApp.swift Smile/Features/EntryEditor/iOSNoteEditorView.swift
git commit -m "feat: 编辑器支持分享照片插入与收图询问"
```

---

## Task 6: RootView 接收分享并打开编辑器

> 注：review 后最终实现与下文不同，以仓库代码为准：照片不经 RootView 中转，留在 `ShareInboxCenter`，由新编辑器 onAppear 时（空白编辑器直接插入）取用；因此编辑器的 `initialImages` 等参数已删除。`openShareEditor()` 只设 `showEntryEditor = true` 并带 1 秒看门狗（按呈现世代复位）；编辑器弹出期间到达的分享会被推迟，编辑器出现后再拉取。

**Files:**
- Modify: `Smile/App/RootView.swift`

- [ ] **Step 1: 新增环境与状态**

在 `@Environment(\.modelContext) private var context` 下加：
```swift
    @Environment(ShareInboxCenter.self) private var shareCenter
    @Environment(\.scenePhase) private var scenePhase
```

在 `@State private var importError: String?` 下加：
```swift
    @State private var shareImages: [UIImage] = []
    @State private var shareFailures = 0
    @State private var showShareReadError = false
```

- [ ] **Step 2: + 号 tab 清空分享状态，sheet 传入照片**

把：
```swift
            Color.clear
                .tabItem { Label("", systemImage: "plus.circle.fill") }
                .onAppear { showEntryEditor = true }
                .tag(1)
```
替换为：
```swift
            Color.clear
                .tabItem { Label("", systemImage: "plus.circle.fill") }
                .onAppear {
                    shareImages = []
                    shareFailures = 0
                    showEntryEditor = true
                }
                .tag(1)
```

把：
```swift
            iOSNoteEditorView(onSaved: { groupID, entryID in
```
替换为：
```swift
            iOSNoteEditorView(initialImages: shareImages,
                              initialImageFailures: shareFailures,
                              onSaved: { groupID, entryID in
```

- [ ] **Step 3: 处理 smilejar://share、前台与编辑器关闭**

把：
```swift
        .onOpenURL { url in
            let ext = url.pathExtension.lowercased()
```
替换为：
```swift
        .onAppear { checkShareInbox() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            shareCenter.purgeStaleTemporaries()
            checkShareInbox()
        }
        .onChange(of: shareCenter.openEditorCount) { _, count in
            guard count == 0 else { return }
            Task { @MainActor in
                // 等上一个编辑器 sheet 的关闭动画结束再弹新的
                try? await Task.sleep(for: .milliseconds(350))
                checkShareInbox()
            }
        }
        .alert("照片读取失败", isPresented: $showShareReadError) {
            // 关闭后继续处理收件箱里可能排着的下一批
            Button("好的", role: .cancel) { checkShareInbox() }
        } message: {
            Text("分享的照片无法读取，请重新分享。")
        }
        .onOpenURL { url in
            if url.scheme == "smilejar" {
                if url.host == "share" { checkShareInbox() }
                return
            }
            let ext = url.pathExtension.lowercased()
```

- [ ] **Step 4: 新增两个方法**

在 `private func handleEditorDismiss()` 之前插入：

```swift
    /// 检查分享收件箱：没有编辑器时直接打开带图编辑器；已有编辑器时由编辑器弹窗询问。
    /// `pullNextBatch` 是 async（后台解码），await 之后必须重新读取编辑器状态。
    private func checkShareInbox() {
        Task { @MainActor in
            // + 号编辑器正在弹出、尚未 onAppear：等它出现后自己弹窗处理
            if showEntryEditor && shareCenter.openEditorCount == 0 { return }
            let result = await shareCenter.pullNextBatch()
            // 解码期间用户可能已打开编辑器：编辑器 onAppear 会看到 incomingImages 并弹窗
            if showEntryEditor || shareCenter.openEditorCount > 0 { return }
            if shareCenter.incomingImages != nil {
                // 新拉到的一批，或编辑器里选了「新建记录」留下的一批
                openShareEditor()
            } else if case .allFailed = result {
                showShareReadError = true
            }
        }
    }

    private func openShareEditor() {
        let incoming = shareCenter.takeIncoming()
        guard !incoming.images.isEmpty else { return }
        shareImages = incoming.images
        shareFailures = incoming.failures
        showEntryEditor = true
    }
```

- [ ] **Step 5: 编译并跑全部测试**

```bash
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: 提交**

```bash
git add Smile/App/RootView.swift
git commit -m "feat: RootView 接收相册分享并打开编辑器"
```

---

## Task 7: README 与真机验证

**Files:**
- Modify: `README.md`

- [ ] **Step 1: README 特性列表**

在 `README.md` 的特性列表中，`- 全库 zip 备份**导出 / 导入恢复**...` 这一行之后加：

```markdown
- **从相册分享**:在「照片」App 选中 1~9 张照片 → 分享 → 微笑储蓄罐,自动新建记录并进入编辑
```

- [ ] **Step 2: 开发者后台配置（需要用户操作）**

在 Apple Developer → Identifiers 中：
1. 新建 App Group `group.com.chuzhanfeng.smile.pic`；
2. 为 `com.chuzhanfeng.smile` 与 `com.chuzhanfeng.smile.pic` 两个 App ID 勾选 App Groups 并选中该 group；
3. Xcode 中两个 target 的 Signing & Capabilities 选择团队，确认 App Groups 显示为已勾选。

- [ ] **Step 3: 真机手动验证（逐项打勾）**

- [ ] 照片 App 分享 1 张 → 自动跳回并进入新编辑器，照片在首行下方，首行获得焦点
- [ ] 分享 9 张 → 顺序与选择一致；选到第 10 张时分享面板不再出现本 App；选中视频时不出现本 App
- [ ] 杀掉 App 后分享（冷启动）→ 编辑器打开且默认选中「微笑储蓄罐」
- [ ] 打开编辑器写一半 → 切到照片 App 分享：
  - [ ] 「插入当前记录」→ 照片插到光标处
  - [ ] 「新建记录」→ 原记录已保存（罐里能看到），随后打开带图新编辑器
  - [ ] 「取消」→ 无变化，再次切回不会重复弹窗
- [ ] 在罐详情页的新增编辑器、记录详情的编辑器中重复上一项
- [ ] 连续分享两次不打开 App → 打开后先处理第一批，关闭编辑器后自动打开第二批
- [ ] HEIC 照片、截图、「文件」App 中的图片均可分享
- [ ] 若跳转失败（扩展显示「请打开微笑储蓄罐继续编辑」），手动打开 App 后能自动进入编辑

- [ ] **Step 4: 提交**

```bash
git add README.md
git commit -m "docs: README 增加相册分享说明"
```
