import SwiftUI

struct RandomRecallSheet: View {
    let entry: Entry
    let onNext: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundGradient.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(Self.formattedDate(entry.createdAt))
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textSecondary)

                        Text(entry.title.isEmpty ? "(无标题)" : entry.title)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)

                        bodyContent

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
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("取出一颗微笑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        onNext()
                    } label: {
                        Label("再来一颗", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Body rendering

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
                                .foregroundStyle(AppColors.textPrimary.opacity(0.85))
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

    private var voiceAttachments: [MediaAttachment] {
        entry.attachments.filter { $0.kind == .voice }.sorted { $0.sortOrder < $1.sortOrder }
    }

    static func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE"
        return f.string(from: date)
    }
}
