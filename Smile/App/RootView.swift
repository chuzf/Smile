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
    /// 密码错误时在密码框里提示，文件保留可重试
    @State private var inboxPasswordHint: String?
    @State private var importing = false
    @State private var importResult: ImportService.ImportResult?
    @State private var importError: String?
    @State private var showShareReadError = false
    /// 编辑器弹出期间到达的分享被推迟了，编辑器出现后再拉取
    @State private var deferredShareCheck = false
    /// 每次 openShareEditor 递增，看门狗只复位自己那一次的呈现
    @State private var shareEditorPresentGen = 0
    /// 别的 sheet / 全屏页挡着时，等它关闭后再弹分享编辑器或读取失败提示
    @State private var sharePresentRetryTask: Task<Void, Never>?

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
            // 「在原处打开」时 url 就是用户的原文件（可能是唯一的备份），只在自己的副本上操作。
            // 复制放到后台：备份可能有几百 MB，iCloud 里未下载的文件还要先下载
            importing = true
            Task {
                let copy = await Task.detached(priority: .userInitiated) {
                    Self.makeImportCopy(of: url)
                }.value
                importing = false
                if let copy {
                    if let old = inboxImportURL { Self.discardImportCopy(old) }
                    inboxImportURL = copy
                } else {
                    importError = "无法读取该备份文件"
                }
            }
        }
        .alert("发现备份文件", isPresented: Binding(
            get: { inboxImportURL != nil && !importing },
            set: { if !$0 { inboxImportURL = nil } }
        )) {
            Button("取消", role: .cancel) {
                if let url = inboxImportURL { Self.discardImportCopy(url) }
                inboxImportURL = nil
            }
            Button("导入") {
                guard let url = inboxImportURL else { return }
                inboxImportURL = nil
                if ExportService.isEncryptedBackup(url) {
                    pendingEncryptedURL = url
                    inboxPasswordHint = nil
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
                guard !pwd.isEmpty else {
                    inboxPasswordHint = "请输入密码"
                    reshowInboxPasswordAlert()
                    return
                }
                pendingEncryptedURL = nil
                Task { await doInboxImport(from: url, password: pwd) }
            }
            Button("取消", role: .cancel) {
                inboxPassword = ""
                inboxPasswordHint = nil
                if let url = pendingEncryptedURL {
                    Self.discardImportCopy(url)
                    pendingEncryptedURL = nil
                }
            }
        } message: {
            Text(inboxPasswordHint ?? "此备份文件已加密，请输入创建备份时设置的密码")
        }
        .alert("导入完成", isPresented: Binding(
            get: { importResult != nil },
            set: { if !$0 { importResult = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            if let r = importResult {
                Text(r.summary)
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
    /// `pullNextBatch` 是 async（后台校验文件），await 之后必须重新读取编辑器状态。
    private func checkShareInbox() {
        Task { @MainActor in
            // + 号编辑器正在弹出、尚未 onAppear：等它出现后自己弹窗处理
            if showEntryEditor && shareCenter.openEditorCount == 0 {
                deferredShareCheck = true
                return
            }
            let result = await shareCenter.pullNextBatch()
            // 校验期间用户可能已打开编辑器：编辑器会看到 incomingPhotoURLs 弹窗询问；
            // 整批读取失败时交给编辑器提示
            if showEntryEditor || shareCenter.openEditorCount > 0 {
                if case .allFailed = result { shareCenter.deferReadFailureNotice() }
                return
            }
            if shareCenter.incomingPhotoURLs != nil {
                // 新拉到的一批，或编辑器里选了「新建记录」留下的一批
                presentWhenUnblocked {
                    if shareCenter.incomingPhotoURLs != nil { openShareEditor() }
                }
            } else if case .allFailed = result {
                presentWhenUnblocked { showShareReadError = true }
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
            // 呈现失败：复位，否则 + 号与后续分享都会失效。照片仍在 shareCenter 中。
            // 是被弹层挡住的（检查之后才出现），等它关闭后再试；原因不明时不立即重试，
            // 避免死循环，留给回到前台或编辑器数量变化时重试
            if showEntryEditor && shareCenter.openEditorCount == 0 {
                showEntryEditor = false
                if Self.isOtherPresentationActive() {
                    presentWhenUnblocked {
                        if shareCenter.incomingPhotoURLs != nil { openShareEditor() }
                    }
                }
            }
        }
    }

    /// 根视图上已有别的 sheet / 全屏页 / alert 时，再呈现会被系统拒绝，而且关掉挡着的弹层不会触发任何重试。
    /// 这里在没有遮挡时立即执行，否则每 0.5 秒检查一次，遮挡消失并等退场动画结束后再执行。
    /// 期间若照片已被别处取走、或已有编辑器打开（比如用户点了 +），就不再执行。
    private func presentWhenUnblocked(_ present: @escaping () -> Void) {
        sharePresentRetryTask?.cancel()
        guard Self.isOtherPresentationActive() else {
            sharePresentRetryTask = nil
            present()
            return
        }
        sharePresentRetryTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, !showEntryEditor, shareCenter.openEditorCount == 0 else { return }
                guard !Self.isOtherPresentationActive() else { continue }
                // 等挡着的弹层退场动画结束
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, !showEntryEditor, shareCenter.openEditorCount == 0 else { return }
                guard !Self.isOtherPresentationActive() else { continue }
                sharePresentRetryTask = nil
                present()
                return
            }
        }
    }

    /// 前台窗口的根控制器上是否正有别的呈现（sheet、全屏页、alert）
    private static func isOtherPresentationActive() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter(\.isKeyWindow)
            .contains { $0.rootViewController?.presentedViewController != nil }
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
        var keepFileForRetry = false
        defer {
            importing = false
            // url 是 onOpenURL 时复制出的副本；密码错误时留着让用户重输
            if !keepFileForRetry { Self.discardImportCopy(url) }
        }

        var importURL = url
        var decryptedURL: URL?

        if let pwd = password, !pwd.isEmpty {
            do {
                decryptedURL = try ExportService.decryptBackup(url: url, password: pwd)
                importURL = decryptedURL!
            } catch ExportService.CryptoError.wrongPassword {
                keepFileForRetry = true
                pendingEncryptedURL = url
                inboxPasswordHint = "密码错误，请重新输入"
                reshowInboxPasswordAlert()
                return
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

    /// 上一个 alert 的关闭动画结束后再弹，否则 SwiftUI 会忽略这次弹出
    private func reshowInboxPasswordAlert() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            // 期间用户已取消或换了别的文件，就不再弹
            guard pendingEncryptedURL != nil else { return }
            showInboxPasswordAlert = true
        }
    }

    nonisolated static func discardImportCopy(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        guard dir.lastPathComponent.hasPrefix("incoming-backup-") else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// 把外部传入的备份复制到临时目录。原文件属于用户，绝不删除；
    /// 只有系统投递到本 App Documents/Inbox 的副本（AirDrop、邮件等）复制后顺手清掉
    nonisolated static func makeImportCopy(of url: URL) -> URL? {
        let fm = FileManager.default
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let dir = fm.temporaryDirectory.appendingPathComponent("incoming-backup-\(UUID().uuidString)")
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        var copyError: Error?
        var coordError: NSError?
        // 协调读取：iCloud 里还没下载到本机的文件会先下载，也不会读到正在写入的半个文件
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.copyItem(at: readURL, to: copy)
            } catch {
                copyError = error
            }
        }
        if coordError != nil || copyError != nil {
            try? fm.removeItem(at: dir)
            return nil
        }

        let inbox = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox").standardizedFileURL.resolvingSymlinksInPath()
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        if source.deletingLastPathComponent().path == inbox.path {
            try? fm.removeItem(at: url)
        }
        return copy
    }
}
