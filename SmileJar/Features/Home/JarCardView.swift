import SwiftUI

struct JarCardView: View {
    let group: Group
    let recentEntry: Entry?
    let onTap: () -> Void

    private var fillRatio: Double {
        // 满罐阈值:50 条记录
        min(1.0, Double(group.entries.count) / 50.0)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                JarView(
                    fillRatio: fillRatio,
                    mainColor: Color(hex: group.colorHex),
                    symbolName: group.iconSymbol
                )
                .frame(width: 64, height: 76)

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(countLine)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textSecondary)
                    Text(previewLine)
                        .font(.system(size: 12))
                        .foregroundStyle(previewColor)
                        .lineLimit(1)
                        .padding(.top, 4)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color(hex: group.colorHex))
            }
            .padding(14)
            .background(AppColors.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private var countLine: String {
        if group.entries.isEmpty { return "0 颗" }
        let n = group.entries.count
        if let recent = recentEntry {
            return "\(n) 颗 · 最近 \(Self.relative(recent.createdAt))"
        }
        return "\(n) 颗"
    }

    private var previewLine: String {
        if let r = recentEntry { return r.title.isEmpty ? "(无标题)" : r.title }
        return "还没有储蓄,点 ＋ 记下今天的微笑吧"
    }

    private var previewColor: Color {
        recentEntry == nil ? AppColors.textSecondary.opacity(0.5) : AppColors.textPrimary.opacity(0.8)
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
