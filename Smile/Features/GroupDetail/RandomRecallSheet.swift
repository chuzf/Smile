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

                        if !entry.bodyText.isEmpty {
                            Text(entry.bodyText)
                                .font(.system(size: 15))
                                .foregroundStyle(AppColors.textPrimary.opacity(0.85))
                                .lineSpacing(4)
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

    static func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE"
        return f.string(from: date)
    }
}
