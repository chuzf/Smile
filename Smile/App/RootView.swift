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
    @State private var pendingEncryptedURL: URL?
    @State private var showInboxPasswordAlert = false
    @State private var inboxPassword = ""
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
