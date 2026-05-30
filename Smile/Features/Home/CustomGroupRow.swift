import SwiftUI

struct CustomGroupRow: View {
    let group: Group
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Circle().fill(Color(hex: group.colorHex)).frame(width: 8, height: 8)
                Text(group.name).font(.system(size: 13))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Text("\(group.entries.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
