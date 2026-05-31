import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context

    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var exportError: String?

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
                .disabled(exporting)
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
        .alert("导出失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    @MainActor
    private func exportAll() async {
        exporting = true
        defer { exporting = false }
        do {
            let url = try ExportService.exportAll(
                context: context, mediaStore: .production()
            )
            exportURL = url
        } catch {
            exportError = error.localizedDescription
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
