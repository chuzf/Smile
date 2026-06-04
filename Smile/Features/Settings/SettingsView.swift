import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(LockSessionManager.self) private var lockSession

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
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        let entries = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
        let hasLockedContent = groups.contains { $0.isLocked } || entries.contains { $0.isLocked }

        if hasLockedContent {
            guard await lockSession.authenticate(reason: "验证身份后才能导出全部记录") else { return }
        }

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
