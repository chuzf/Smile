import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// Custom UTType for encrypted backup files
private extension UTType {
    static let smilejarBackup = UTType(exportedAs: "com.smilejar.backup", conformingTo: .data)
}

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(LockSessionManager.self) private var lockSession

    // Export state
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var exportError: String?
    @State private var showExportRiskAlert = false
    @State private var showExportPasswordAlert = false
    @State private var exportPassword = ""
    @State private var exportPasswordConfirm = ""

    // Import state
    @State private var showFilePicker = false
    @State private var importing = false
    @State private var importResult: ImportService.ImportResult?
    @State private var importError: String?
    @State private var showImportPasswordAlert = false
    @State private var importPassword = ""
    @State private var pendingImportURL: URL?

    var body: some View {
        Form {
            Section("功能") {
                NavigationLink("AI 自动标题") { AISettingsView() }
            }
            Section("数据") {
                Button {
                    Task { await startExport() }
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

        // MARK: Share sheet（导出完成后分享文件）
        .sheet(item: Binding<ExportFileWrapper?>(
            get: { exportURL.map { ExportFileWrapper(url: $0) } },
            set: { _ in exportURL = nil }
        )) { w in
            ShareSheetForURL(url: w.url)
        }

        // MARK: File picker（导入）
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.zip, .smilejarBackup]
        ) { result in
            handleFilePicked(result)
        }

        // MARK: 导出风险提示
        .alert("导出说明", isPresented: $showExportRiskAlert) {
            Button("设置密码") { showExportPasswordAlert = true }
            Button("直接导出") { Task { await performExport(password: nil) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("备份文件包含全部记录（含加锁内容），建议设置密码保护。不加密的备份任何人均可直接读取。")
        }

        // MARK: 导出密码输入
        .alert("设置导出密码", isPresented: $showExportPasswordAlert) {
            SecureField("密码", text: $exportPassword)
            SecureField("确认密码", text: $exportPasswordConfirm)
            Button("导出") {
                let pwd = exportPassword
                let confirm = exportPasswordConfirm
                exportPassword = ""
                exportPasswordConfirm = ""
                if pwd.isEmpty || pwd != confirm {
                    exportError = "两次输入的密码不一致或密码为空，请重新操作"
                } else {
                    Task { await performExport(password: pwd) }
                }
            }
            Button("取消", role: .cancel) {
                exportPassword = ""
                exportPasswordConfirm = ""
            }
        } message: {
            Text("加密后导出 .smilejar 文件，导入时需输入此密码。请妥善保存密码，遗忘后无法恢复。")
        }

        // MARK: 导入密码输入
        .alert("输入备份密码", isPresented: $showImportPasswordAlert) {
            SecureField("密码", text: $importPassword)
            Button("导入") {
                guard let url = pendingImportURL else { return }
                let pwd = importPassword
                importPassword = ""
                pendingImportURL = nil
                Task { await doImport(from: url, password: pwd) }
            }
            Button("取消", role: .cancel) {
                importPassword = ""
                if let url = pendingImportURL {
                    try? FileManager.default.removeItem(at: url)
                    pendingImportURL = nil
                }
            }
        } message: {
            Text("此备份文件已加密，请输入创建备份时设置的密码")
        }

        // MARK: 结果 / 错误提示
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
    private func startExport() async {
        let groups = (try? context.fetch(FetchDescriptor<Group>())) ?? []
        let entries = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
        let hasLockedContent = groups.contains { $0.isLocked } || entries.contains { $0.isLocked }
        if hasLockedContent {
            guard await lockSession.authenticate(reason: "验证身份后才能导出全部记录") else { return }
        }
        showExportRiskAlert = true
    }

    @MainActor
    private func performExport(password: String?) async {
        exporting = true
        defer { exporting = false }
        do {
            exportURL = try ExportService.exportAll(
                context: context, mediaStore: .production(), password: password)
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

            if ExportService.isEncryptedBackup(tempURL) {
                pendingImportURL = tempURL
                showImportPasswordAlert = true
            } else {
                Task { await doImport(from: tempURL, password: nil) }
            }
        }
    }

    @MainActor
    private func doImport(from url: URL, password: String?) async {
        importing = true
        defer { importing = false }

        var importURL = url
        var decryptedURL: URL?

        if let pwd = password, !pwd.isEmpty {
            do {
                decryptedURL = try ExportService.decryptBackup(url: url, password: pwd)
                importURL = decryptedURL!
            } catch {
                try? FileManager.default.removeItem(at: url)
                importError = error.localizedDescription
                return
            }
        }

        defer {
            try? FileManager.default.removeItem(at: url)
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
