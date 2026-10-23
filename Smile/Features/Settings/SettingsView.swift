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
    /// 导出完成后生成一次并保持不变：sheet 的 id 不能随刷新变化，否则面板会被关掉重开，文件被提前删除
    @State private var exportFile: ExportFileWrapper?
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
    /// 密码为空或错误时在密码框里提示，文件保留可重试
    @State private var importPasswordHint: String?
    @State private var pendingExportCleanup: [URL] = []

    @AppStorage(ArticleStyle.storageKey) private var articleStyleRaw = ArticleStyle.default.rawValue

    var body: some View {
        Form {
            Section("AI") {
                NavigationLink {
                    AISettingsView()
                } label: {
                    Label("AI 整理", systemImage: "wand.and.stars")
                }
            }
            Section {
                Picker("详情排版", selection: $articleStyleRaw) {
                    ForEach(ArticleStyle.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                ArticleStylePreview(style: ArticleStyle(rawValue: articleStyleRaw) ?? .default)
                    .listRowInsets(EdgeInsets())
            } header: {
                Text("阅读")
            } footer: {
                Text("只改变记录详情页的显示效果，不影响已保存的内容。")
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
        .sheet(item: $exportFile, onDismiss: {
            // 面板完全关闭后再删：备份含加锁内容，不能一直留在临时目录
            for url in pendingExportCleanup { try? FileManager.default.removeItem(at: url) }
            pendingExportCleanup.removeAll()
        }) { w in
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
                guard !pwd.isEmpty else {
                    importPasswordHint = "请输入密码"
                    reshowImportPasswordAlert()
                    return
                }
                pendingImportURL = nil
                Task { await doImport(from: url, password: pwd) }
            }
            Button("取消", role: .cancel) {
                importPassword = ""
                importPasswordHint = nil
                if let url = pendingImportURL {
                    try? FileManager.default.removeItem(at: url)
                    pendingImportURL = nil
                }
            }
        } message: {
            Text(importPasswordHint ?? "此备份文件已加密，请输入创建备份时设置的密码")
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
            let url = try ExportService.exportAll(
                context: context, mediaStore: .production(), password: password)
            pendingExportCleanup.append(url)
            exportFile = ExportFileWrapper(url: url)
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
                importPasswordHint = nil
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
            } catch ExportService.CryptoError.wrongPassword {
                // 保留临时副本，让用户重新输入，不必重新选文件
                pendingImportURL = url
                importPasswordHint = "密码错误，请重新输入"
                reshowImportPasswordAlert()
                return
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

    /// 上一个 alert 关闭后再弹，否则 SwiftUI 会忽略这次弹出
    private func reshowImportPasswordAlert() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard pendingImportURL != nil else { return }
            showImportPasswordAlert = true
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

/// 设置页里按所选风格实时渲染的一小段示例
private struct ArticleStylePreview: View {
    let style: ArticleStyle

    private static let sample = "早上醒来，窗外下着小雨。孩子趴在窗边看了好久，说雨滴像是在玻璃上赛跑。\n吃过早饭，我们撑着伞去了楼下的小公园，她穿着新雨靴踩过一个个小水洼。"

    var body: some View {
        ArticleTextBlock(text: Self.sample, centered: false, style: style)
            .padding(.horizontal, style.metrics.horizontalMargin)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            .background(style.background)
            .animation(.easeInOut(duration: 0.2), value: style)
    }
}
