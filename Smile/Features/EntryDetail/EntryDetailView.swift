import SwiftUI
import SwiftData

struct EntryDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(LockSessionManager.self) private var lockSession
    @Bindable var entry: Entry

    @State private var showEditor = false
    @State private var sharedImage: UIImage?
    @State private var showShareSheet = false
    @State private var viewerItem: PhotoViewerItem?

    @AppStorage(ArticleStyle.storageKey) private var styleRaw = ArticleStyle.default.rawValue

    private var style: ArticleStyle { ArticleStyle(rawValue: styleRaw) ?? .default }

    var body: some View {
        ZStack {
            style.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 28)

                    bodyContent

                    footer
                }
                .padding(.horizontal, style.metrics.horizontalMargin)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("编辑", systemImage: "pencil") { showEditor = true }
                    Button("生成分享图", systemImage: "square.and.arrow.up") { generateShareImage() }
                    if entry.isLocked {
                        Button("取消锁定", systemImage: "lock.open") { toggleLock() }
                    } else {
                        Button("锁定此条目", systemImage: "lock") { toggleLock() }
                    }
                    Button("删除", systemImage: "trash", role: .destructive) { deleteEntry() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fullScreenCover(item: $viewerItem) { item in
            PhotoViewer(urls: item.urls, initialIndex: item.initialIndex) { viewerItem = nil }
                .presentationBackground(.clear)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.title.isEmpty ? "(无标题)" : entry.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(uiColor: ArticleStyle.bodyColor))
                    .lineSpacing(6)
                if entry.titleSource == .ai {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.warmOrange)
                }
            }
            HStack(spacing: 8) {
                if let groupName = entry.group?.name, !groupName.isEmpty {
                    Text(groupName).foregroundStyle(AppColors.warmOrange)
                }
                Text(dateLabel).foregroundStyle(AppColors.textSecondary)
            }
            .font(.system(size: 14))
        }
    }

    /// 正文段之间、正文与图片之间的间距
    private static let blockSpacing: CGFloat = 24

    @ViewBuilder
    private var bodyContent: some View {
        let segs = parseBodySegments()
        if !segs.isEmpty {
            VStack(alignment: .leading, spacing: Self.blockSpacing) {
                ForEach(segs.indices, id: \.self) { idx in
                    let seg = segs[idx]
                    switch seg.kind {
                    case .text:
                        if let text = seg.content, !ArticleStyle.paragraphs(from: text).isEmpty {
                            ArticleTextBlock(text: text, centered: seg.alignment == "center", style: style)
                        }
                    case .photo:
                        if let path = seg.path, let url = existingPhotoURL(path) {
                            DetailPhotoView(url: url, cornerRadius: style.metrics.photoCornerRadius) {
                                openViewer(at: url, in: segs)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if !voiceAttachments.isEmpty || !entry.tags.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Divider()
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
            .padding(.top, 32)
        }
    }

    /// 文件不存在的照片不显示，也不进查看器
    private func existingPhotoURL(_ path: String) -> URL? {
        let url = MediaStore.production().absoluteURL(relativePath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func openViewer(at url: URL, in segs: [BodySegment]) {
        let urls = segs.compactMap { seg -> URL? in
            guard seg.kind == .photo, let path = seg.path else { return nil }
            return existingPhotoURL(path)
        }
        viewerItem = PhotoViewerItem(urls: urls, initialIndex: urls.firstIndex(of: url) ?? 0)
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

    private func toggleLock() {
        Task { @MainActor in
            if entry.isLocked {
                guard await lockSession.authenticate(reason: "验证身份以取消锁定") else { return }
            }
            entry.isLocked.toggle()
            try? context.save()
        }
    }

    private func deleteEntry() {
        let entryID = entry.id
        dismiss()
        Task { @MainActor in
            try? MediaStore.production().deleteEntryDirectory(entryID: entryID)
            context.delete(entry)
            try? context.save()
        }
    }
}

private struct ShareImageWrapper: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - 正文照片

/// 后台解码缩小后的图并缓存；加载前用文件头里的尺寸占位，避免布局跳动
private struct DetailPhotoView: View {
    /// 屏幕宽度 × 3 倍屏，足够正文显示；放大查看由 PhotoViewer 读原图
    static let maxPixel = 1600

    let url: URL
    let cornerRadius: CGFloat
    let onTap: () -> Void

    @State private var image: UIImage?
    @State private var aspectRatio: CGFloat?
    @State private var failed = false

    var body: some View {
        if !failed {
            content
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .contentShape(Rectangle())
                .onTapGesture { if image != nil { onTap() } }
                .task(id: url) { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(AppColors.cardSurface)
                .aspectRatio(aspectRatio ?? 4 / 3, contentMode: .fit)
        }
    }

    private func load() async {
        let url = url
        // 先读文件头定好占位比例，再解码图片
        let size = await Task.detached(priority: .userInitiated) { ImageLoader.orientedPixelSize(url: url) }.value
        if let size, size.height > 0 { aspectRatio = size.width / size.height }
        let loaded = await Task.detached(priority: .userInitiated) {
            ImageLoader.cachedDownsampled(url: url, maxPixel: Self.maxPixel)
        }.value
        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
    }
}
