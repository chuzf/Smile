# Open-In Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 注册 SmileJar 为 `.zip` 文件处理程序，让用户可以从微信/邮件/AirDrop 直接"用其他应用打开"触发导入。

**Architecture:** `Info.plist` 声明接受 `public.zip-archive`，iOS 把文件复制到 App 的 `Documents/Inbox/`，`RootView` 通过 `.onOpenURL` 监听到 URL 后弹出确认 Alert，用户确认后调用已有的 `ImportService.importBackup`。

**Tech Stack:** SwiftUI, SwiftData, iOS 17+, 已有 ImportService

---

## 文件清单

| 操作 | 路径 |
|------|------|
| 修改 | `Smile/Info.plist` |
| 修改 | `Smile/App/RootView.swift` |

---

## Task 1: 注册 App 为 zip 文件处理程序

**Files:**
- Modify: `Smile/Info.plist`

- [ ] **Step 1: 在 Info.plist 的 `</dict>` 前插入 CFBundleDocumentTypes**

找到文件末尾：
```xml
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
	</array>
</dict>
</plist>
```

改为：
```xml
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
	</array>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>SmileJar 备份</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.zip-archive</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: 编译验证**

```bash
xcodebuild build -project /Users/chuzhanfeng/work/claude/smile/Smile.xcodeproj -scheme Smile -destination 'id=A0182626-E370-4C52-9440-932264DCDC30' 2>&1 | grep "BUILD"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Smile/Info.plist
git commit -m "feat: register app as zip file handler for Open-In import"
```

---

## Task 2: RootView 增加 onOpenURL 导入流程

**Files:**
- Modify: `Smile/App/RootView.swift`

- [ ] **Step 1: 将 RootView.swift 全文替换为以下内容**

```swift
import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var showEntryEditor = false
    @State private var selectedTab = 0
    @State private var groupNav: GroupNavigation?
    @State private var pendingGroupID: UUID?
    @State private var pendingEntryID: UUID?

    @State private var inboxImportURL: URL?
    @State private var importing = false
    @State private var importResult: ImportService.ImportResult?
    @State private var importError: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(externalNav: $groupNav)
                .tabItem { Label("罐", systemImage: "drop.circle") }
                .tag(0)

            Color.clear
                .tabItem { Label("", systemImage: "plus.circle.fill") }
                .onAppear { showEntryEditor = true }
                .tag(1)

            MeTabView()
                .tabItem { Label("我", systemImage: "person.circle") }
                .tag(2)
        }
        .tint(AppColors.warmOrange)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showEntryEditor, onDismiss: handleEditorDismiss) {
            iOSNoteEditorView(onSaved: { groupID, entryID in
                pendingGroupID = groupID
                pendingEntryID = entryID
                selectedTab = 0
            })
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "zip" else { return }
            inboxImportURL = url
        }
        .alert("发现备份文件", isPresented: Binding(
            get: { inboxImportURL != nil && !importing },
            set: { if !$0 { inboxImportURL = nil } }
        )) {
            Button("取消", role: .cancel) { inboxImportURL = nil }
            Button("导入") {
                if let url = inboxImportURL {
                    inboxImportURL = nil
                    Task { await doInboxImport(from: url) }
                }
            }
        } message: {
            Text("是否立即导入此备份？")
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

    private func handleEditorDismiss() {
        guard let gid = pendingGroupID, let eid = pendingEntryID else { return }
        pendingGroupID = nil
        pendingEntryID = nil
        selectedTab = 0
        groupNav = GroupNavigation(groupID: gid, highlightEntryID: eid)
    }

    @MainActor
    private func doInboxImport(from url: URL) async {
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
```

- [ ] **Step 2: 编译验证**

```bash
xcodebuild build -project /Users/chuzhanfeng/work/claude/smile/Smile.xcodeproj -scheme Smile -destination 'id=A0182626-E370-4C52-9440-932264DCDC30' 2>&1 | grep "BUILD"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 运行全套测试，确认无回归**

```bash
xcodebuild test -project /Users/chuzhanfeng/work/claude/smile/Smile.xcodeproj -scheme SmileTests -destination 'id=A0182626-E370-4C52-9440-932264DCDC30' 2>&1 | grep -E "Test run|passed|failed" | tail -3
```

Expected: `Test run with N tests in N suites passed`

- [ ] **Step 4: Commit**

```bash
git add Smile/App/RootView.swift
git commit -m "feat: handle Open-In zip files in RootView for direct import"
```
