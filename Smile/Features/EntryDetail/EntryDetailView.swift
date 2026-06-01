import SwiftUI
import SwiftData

struct EntryDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var entry: Entry

    @State private var showEditor = false
    @State private var sharedImage: UIImage?
    @State private var showShareSheet = false

    var body: some View {
        ZStack {
            AppColors.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(dateLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textSecondary)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.title.isEmpty ? "(无标题)" : entry.title)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                        if entry.titleSource == .ai {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12))
                                .foregroundStyle(AppColors.warmOrange)
                        }
                    }

                    bodyContent

                    ForEach(voiceAttachments) { att in
                        VoicePlayerRow(attachment: att)
                    }

                    if !entry.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(entry.tags) { tag in
                                TagChip(name: tag.name,
                                        color: Color(hex: tag.colorHex),
                                        selected: false)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("编辑", systemImage: "pencil") { showEditor = true }
                    Button("生成分享图", systemImage: "square.and.arrow.up") { generateShareImage() }
                    Button("删除", systemImage: "trash", role: .destructive) { deleteEntry() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            iOSNoteEditorView(editingEntryID: entry.persistentModelID)
        }
        .sheet(isPresented: $showShareSheet, onDismiss: { sharedImage = nil }) {
            if let img = sharedImage {
                ShareSheet(image: img)
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        let segs = parseBodySegments()
        if !segs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(segs.indices, id: \.self) { idx in
                    let seg = segs[idx]
                    switch seg.kind {
                    case .text:
                        if let text = seg.content, !text.isEmpty {
                            Text(text)
                                .font(.system(size: 15))
                                .foregroundStyle(AppColors.textPrimary.opacity(0.9))
                                .lineSpacing(4)
                                .multilineTextAlignment(seg.textAlignment)
                                .frame(maxWidth: .infinity, alignment: seg.frameAlignment)
                        }
                    case .photo:
                        if let path = seg.path,
                           let data = try? MediaStore.production().loadData(relativePath: path),
                           let img = UIImage(data: data) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func parseBodySegments() -> [BodySegment] {
        if let segs = iOSNoteEditorModel.decodeBodySegments(from: entry.bodyText) {
            return segs
        }
        if entry.bodyText.isEmpty { return [] }
        return [BodySegment(kind: .text, content: entry.bodyText, path: nil, alignment: nil)]
    }

    private var photoAttachments: [MediaAttachment] {
        entry.attachments.filter { $0.kind == .photo }.sorted { $0.sortOrder < $1.sortOrder }
    }
    private var voiceAttachments: [MediaAttachment] {
        entry.attachments.filter { $0.kind == .voice }.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        return f.string(from: entry.createdAt)
    }

    private func generateShareImage() {
        let firstPhoto = photoAttachments.first
        var primary: UIImage?
        if let p = firstPhoto,
           let data = try? MediaStore.production().loadData(relativePath: p.relativePath) {
            primary = UIImage(data: data)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        let data = ShareCardRenderer.CardData(
            groupName: entry.group?.name ?? "微笑储蓄罐",
            dateText: f.string(from: entry.createdAt),
            title: entry.title.isEmpty ? "(无标题)" : entry.title,
            bodySnippet: String(iOSNoteEditorModel.plainText(from: entry.bodyText).prefix(120)),
            primaryImage: primary
        )
        sharedImage = ShareCardRenderer.render(data)
        showShareSheet = true
    }

    private func deleteEntry() {
        try? MediaStore.production().deleteEntryDirectory(entryID: entry.id)
        context.delete(entry)
        try? context.save()
        dismiss()
    }
}

private struct ShareImageWrapper: Identifiable {
    let id = UUID()
    let image: UIImage
}
