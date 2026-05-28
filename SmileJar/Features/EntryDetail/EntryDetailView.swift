import SwiftUI
import SwiftData

struct EntryDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var entry: Entry

    @State private var showEditor = false
    @State private var sharedImage: UIImage?

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

                    PhotoCarousel(photoPaths: photoAttachments.map { $0.relativePath })

                    if !entry.bodyText.isEmpty {
                        Text(entry.bodyText)
                            .font(.system(size: 15))
                            .foregroundStyle(AppColors.textPrimary.opacity(0.9))
                            .lineSpacing(4)
                    }

                    ForEach(voiceAttachments) { att in
                        VoicePlayerRow(attachment: att)
                    }

                    if !entry.tags.isEmpty {
                        HStack {
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
        .sheet(item: Binding<ShareImageWrapper?>(
            get: { sharedImage.map { ShareImageWrapper(image: $0) } },
            set: { _ in sharedImage = nil }
        )) { wrapper in
            ShareSheet(image: wrapper.image)
        }
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
            bodySnippet: String(entry.bodyText.prefix(120)),
            primaryImage: primary
        )
        sharedImage = ShareCardRenderer.render(data)
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
