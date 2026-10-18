import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(ShareInboxCenter.self) private var shareCenter
    @Environment(\.scenePhase) private var scenePhase
    @State private var showEntryEditor = false
    @State private var selectedTab = 0
    @State private var groupNav: GroupNavigation?
    @State private var pendingGroupID: UUID?
    @State private var pendingEntryID: UUID?

    @State private var inboxImportURL: URL?
    @State private var pendingEncryptedURL: URL?
    @State private var showInboxPasswordAlert = false
    @State private var inboxPassword = ""
    @State private var importing = false
    @State private var importResult: ImportService.ImportResult?
    @State private var importError: String?
    @State private var showShareReadError = false
    /// 编辑器弹出期间到达的分享被推迟了，编辑器出现后再拉取
    @State private var deferredShareCheck = false
    /// 每次 openShareEditor 递增，看门狗只复位自己那一次的呈现
    @State private var shareEditorPresentGen = 0

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
            // 分享的照片留在 shareCenter 中，由新编辑器 onAppear 时自己取用并插入
            iOSNoteEditorView(onSaved: { groupID, entryID in
                pendingGroupID = groupID
                pendingEntryID = entryID
                selectedTab = 0
            })
        }
        .onAppear { checkShareInbox() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            shareCenter.purgeStaleTemporaries()
            checkShareInbox()
        }
        .onChange(of: shareCenter.openEditorCount) { _, count in
            guard count == 0 else {
                // 编辑器弹出期间到达的分享（checkShareInbox 当时提前返回了）：现在拉取，编辑器会弹窗询问。
                // 只处理被推迟的那次，避免分享编辑器一出现就为收件箱里的下一批弹窗
                if deferredShareCheck {
                    deferredShareCheck = false
                    checkShareInbox()
                }
                return
            }
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
            guard ext == "zip" || ext == "smilejar" else { return }
            inboxImportURL = url
        }
        .alert("发现备份文件", isPresented: Binding(
            get: { inboxImportURL != nil && !importing },
            set: { if !$0 { inboxImportURL = nil } }
        )) {
            Button("取消", role: .cancel) { inboxImportURL = nil }
            Button("导入") {
                guard let url = inboxImportURL else { return }
                inboxImportURL = nil
                if ExportService.isEncryptedBackup(url) {
                    pendingEncryptedURL = url
                    showInboxPasswordAlert = true
                } else {
                    Task { await doInboxImport(from: url, password: nil) }
                }
            }
        } message: {
            Text("是否立即导入此备份？")
        }
        .alert("输入备份密码", isPresented: $showInboxPasswordAlert) {
            SecureField("密码", text: $inboxPassword)
            Button("导入") {
                guard let url = pendingEncryptedURL else { return }
                let pwd = inboxPassword
                inboxPassword = ""
                pendingEncryptedURL = nil
                Task { await doInboxImport(from: url, password: pwd) }
            }
            Button("取消", role: .cancel) {
                inboxPassword = ""
                if let url = pendingEncryptedURL {
                    try? FileManager.default.removeItem(at: url)
                    pendingEncryptedURL = nil
                }
            }
        } message: {
            Text("此备份文件已加密，请输入创建备份时设置的密码")
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

    /// 检查分享收件箱：没有编辑器时直接打开带图编辑器；已有编辑器时由编辑器弹窗询问。
    /// `pullNextBatch` 是 async（后台解码），await 之后必须重新读取编辑器状态。
    private func checkShareInbox() {
        Task { @MainActor in
            // + 号编辑器正在弹出、尚未 onAppear：等它出现后自己弹窗处理
            if showEntryEditor && shareCenter.openEditorCount == 0 {
                deferredShareCheck = true
                return
            }
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

    /// 照片留在 shareCenter 里，新编辑器 onAppear 时发现是空白编辑器会直接取用插入。
    /// 不切换 selectedTab：sheet 挂在 TabView 上，任意 tab 下都能弹出。
    private func openShareEditor() {
        showEntryEditor = true
        shareEditorPresentGen += 1
        let gen = shareEditorPresentGen
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard gen == shareEditorPresentGen else { return }
            // 呈现失败（已有别的 sheet/alert 在呈现）：复位，否则 + 号与后续分享都会失效。
            // 照片仍在 shareCenter 中，下次回到前台或编辑器数量变化时会重试
            if showEntryEditor && shareCenter.openEditorCount == 0 {
                showEntryEditor = false
            }
        }
    }

    private func handleEditorDismiss() {
        // 从 + 号 tab 打开的编辑器关闭后回到“罐”列表页（无论保存还是取消），
        // 避免停留在中间 + 号那个空白 tab；从其它 tab 打开的分享编辑器关闭后留在原 tab。
        // 保存时 onSaved 已切到“罐”页。
        if selectedTab == 1 { selectedTab = 0 }
        guard let gid = pendingGroupID, let eid = pendingEntryID else { return }
        pendingGroupID = nil
        pendingEntryID = nil
        groupNav = GroupNavigation(groupID: gid, highlightEntryID: eid)
    }

    @MainActor
    private func doInboxImport(from url: URL, password: String?) async {
        importing = true
        defer {
            importing = false
            try? FileManager.default.removeItem(at: url)
        }

        var importURL = url
        var decryptedURL: URL?

        if let pwd = password, !pwd.isEmpty {
            do {
                decryptedURL = try ExportService.decryptBackup(url: url, password: pwd)
                importURL = decryptedURL!
            } catch {
                importError = error.localizedDescription
                return
            }
        }

        defer {
            if let du = decryptedURL { try? FileManager.default.removeItem(at: du) }
        }

        do {
            importResult = try ImportService.importBackup(
                from: importURL, context: context, mediaStore: .production())
        } catch {
            importError = error.localizedDescription
        }
    }
}
