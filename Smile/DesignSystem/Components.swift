import SwiftUI

// MARK: - 卡片背景容器
struct WarmCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .background(AppColors.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - 主 CTA 按钮
struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 24)
                .background(Capsule().fill(AppColors.warmOrange))
        }
    }
}

// MARK: - 标签 chip
struct TagChip: View {
    let name: String
    let color: Color
    let selected: Bool

    var body: some View {
        Text("#\(name)")
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? .white : AppColors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(selected ? color : color.opacity(0.18))
            )
    }
}

// MARK: - 空态视图
struct EmptyStateView: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(AppColors.textSecondary.opacity(0.6))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

#Preview {
    VStack(spacing: 20) {
        WarmCard { Text("卡片内容").padding() }
        PrimaryButton(title: "随机看一颗") {}
        HStack {
            TagChip(name: "家人", color: AppColors.warmOrange, selected: true)
            TagChip(name: "走路", color: AppColors.leafGreen, selected: false)
        }
        EmptyStateView(icon: "tray", message: "还没有储蓄,点 ＋ 记下今天的微笑吧")
    }
    .padding()
    .background(AppColors.backgroundGradient)
}
