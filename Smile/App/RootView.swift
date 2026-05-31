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
