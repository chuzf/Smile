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
    @State private var shareImages: [UIImage] = []
    @State private var shareFailures = 0
    @State private var showShareReadError = false

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(externalNav: $groupNav)
                .tabItem { Label("罐", systemImage: "drop.circle") }
                .tag(0)

            Color.clear
                .tabItem { Label("", systemImage: "plus.circle.fill") }
                .onAppear {
                    shareImages = []
                    shareFailures = 0
                    showEntryEditor = true
                }
                .tag(1)

            MeTabView()
                .tabItem { Label("我", systemImage: "person.circle") }
                .tag(2)
        }
        .tint(AppColors.warmOrange)
        .preferredColorScheme(.light)
        // 捕获列表让 body 读取 shareImages/shareFailures：否则它们与 showEntryEditor 同时被设置时，
        // sheet 内容会先用旧的空数组构建，编辑器 onAppear 拿不到分享的照片
        .sheet(isPresented: $showEntryEditor, onDismiss: handleEditorDismiss) { [shareImages, shareFailures] in
            entryEditor(images: shareImages, failures: shareFailures)
        }
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

    private func entryEditor(images: [UIImage], failures: Int) -> some View {
        iOSNoteEditorView(initialImages: images,
                          initialImageFailures: failures,
                          onInitialImagesConsumed: {
                              // 照片已插入编辑器，释放这里持有的解码大图
                              shareImages = []
                              shareFailures = 0
                          },
                          onSaved: { groupID, entryID in
                              pendingGroupID = groupID
                              pendingEntryID = entryID
                              selectedTab = 0
                          })
    }

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

    /// 不切换 selectedTab：sheet 挂在 TabView 上，任意 tab 下都能弹出
    private func openShareEditor() {
        let incoming = shareCenter.takeIncoming()
        guard !incoming.images.isEmpty else { return }
        shareImages = incoming.images
        shareFailures = incoming.failures
        showEntryEditor = true
    }

    private func handleEditorDismiss() {
        // 关闭编辑器后总是回到“罐”列表页（无论保存还是取消），
        // 避免取消时停留在中间 + 号那个空白 tab。
        selectedTab = 0
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
