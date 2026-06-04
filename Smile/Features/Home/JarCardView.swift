import SwiftUI

struct JarCardView: View {
    let group: Group
    let recentEntry: Entry?
    let isLocked: Bool
    let onTap: () -> Void

    private var fillRatio: Double {
        min(1.0, Double(group.entries.count) / 50.0)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    JarView(
                        fillRatio: fillRatio,
                        mainColor: Color(hex: group.colorHex),
                        symbolName: group.iconSymbol
                    )
                    .frame(width: 64, height: 76)

                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppColors.warmOrange)
                            .padding(4)
                            .background(AppColors.cardSurface)
                            .clipShape(Circle())
                            .offset(x: 2, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(countLine)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textSecondary)

                    if isLocked {
                        Label("已锁定 · 点击验证身份", systemImage: "lock.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.warmOrange)
                            .padding(.top, 4)
                    } else {
                        Text(previewLine)
                            .font(.system(size: 12))
                            .foregroundStyle(previewColor)
                            .lineLimit(1)
                            .padding(.top, 4)
                    }
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color(hex: group.colorHex))
            }
            .padding(14)
            .background(AppColors.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .opacity(isLocked ? 0.85 : 1.0)
        }
        .buttonStyle(.plain)
    }

    private var countLine: String {
        if group.entries.isEmpty { return "0 颗" }
        let n = group.entries.count
        if let recent = recentEntry, !isLocked {
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
