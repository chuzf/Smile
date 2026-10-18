import SwiftUI

struct FormattingPreview: Identifiable {
    let id = UUID()
    let snapshot: FormattingSnapshot
    let result: FormattingResult
}

struct FormattingPreviewSheet: View {
    let preview: FormattingPreview
    let onReplace: () -> Void
    let onCancel: () -> Void

    @State private var showOriginal = false

    private var title: String { showOriginal ? preview.snapshot.input.title : preview.result.title }
    private var segments: [String] { showOriginal ? preview.snapshot.input.segments : preview.result.segments }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $showOriginal) {
                    Text("整理后").tag(false)
                    Text("原文").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title.isEmpty ? "（无标题）" : title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(title.isEmpty ? AppColors.textSecondary : AppColors.textPrimary)
                        ForEach(Array(preview.snapshot.layout.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
            .background(AppColors.backgroundGradient.ignoresSafeArea())
            .navigationTitle("整理结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("替换", action: onReplace).fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: FormattingSnapshot.Block) -> some View {
        switch block {
        case .text(let index):
            if !segments[index].isEmpty {
                Divider()
                Text(segments[index])
                    .font(.system(size: 16))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .photo:
            Divider()
            Text("［照片］")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textSecondary)
        }
    }
}
