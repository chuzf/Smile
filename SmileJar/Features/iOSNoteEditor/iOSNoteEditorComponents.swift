import SwiftUI
import SwiftData

// Alias to disambiguate SwiftUI.Group from our data model
typealias SwiftUIGroup = SwiftUI.Group

// MARK: - Navigation Bar
struct iOSNoteEditorNavBar: View {
    let dateLabel: String
    let isSaving: Bool
    let onBack: () -> Void
    let onComplete: () -> Void
    let canComplete: Bool

    var body: some View {
        ZStack {
            AppColors.backgroundGradient
                .ignoresSafeArea()

            HStack(spacing: 0) {
                // Back Button
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                }

                Spacer()

                // Date Label
                Text(dateLabel)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(AppColors.textSecondary)

                Spacer()

                // Complete/Loading Button
                if isSaving {
                    ProgressView()
                        .tint(AppColors.warmOrange)
                } else {
                    Button(action: onComplete) {
                        Text("完成")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .disabled(!canComplete)
                    .opacity(canComplete ? 1.0 : 0.5)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(height: 56)
    }
}

// MARK: - Group Selector
struct GroupSelector: View {
    @Binding var selectedGroupID: PersistentIdentifier?
    let builtinGroups: [Group]
    let customGroups: [Group]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Built-in Groups
                ForEach(builtinGroups, id: \.id) { group in
                    groupPill(group)
                }

                // Divider
                if !customGroups.isEmpty {
                    Divider()
                        .frame(height: 18)
                        .padding(.horizontal, 4)
                }

                // Custom Groups
                ForEach(customGroups, id: \.id) { group in
                    groupPill(group)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func groupPill(_ group: Group) -> some View {
        let groupColor = Color(hex: group.colorHex)
        let isSelected = selectedGroupID == group.id

        Button(action: {
            selectedGroupID = group.id
        }) {
            HStack(spacing: 6) {
                Image(systemName: group.iconSymbol)
                Text(group.name)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isSelected ? .white : groupColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? groupColor
                    : groupColor.opacity(0.15)
            )
            .cornerRadius(20)
        }
    }
}

// MARK: - Tool Bar
struct iOSNoteEditorToolBar: View {
    let onPhotoTap: () -> Void
    let onVoiceTap: () -> Void
    let onTagsTap: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            // Photo Button
            Button(action: onPhotoTap) {
                Label("照片", systemImage: "photo")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(AppColors.warmOrange)
            }

            // Voice Button
            Button(action: onVoiceTap) {
                Label("语音", systemImage: "mic")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(AppColors.warmOrange)
            }

            // Tags Button
            Button(action: onTagsTap) {
                Label("标签", systemImage: "number")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(AppColors.warmOrange)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    VStack(spacing: 0) {
        iOSNoteEditorNavBar(
            dateLabel: "2026年5月28日",
            isSaving: false,
            onBack: {},
            onComplete: {},
            canComplete: true
        )

        GroupSelector(
            selectedGroupID: .constant(nil),
            builtinGroups: [
                Group(name: "微笑罐", iconSymbol: "smileyface", colorHex: "#E08A4A", isBuiltIn: true),
                Group(name: "优势罐", iconSymbol: "leaf", colorHex: "#7AA350", isBuiltIn: true),
            ],
            customGroups: [
                Group(name: "工作", iconSymbol: "briefcase", colorHex: "#D8A3C4", isBuiltIn: false),
                Group(name: "生活", iconSymbol: "heart", colorHex: "#A3C9E8", isBuiltIn: false),
            ]
        )

        Spacer()

        iOSNoteEditorToolBar(
            onPhotoTap: {},
            onVoiceTap: {},
            onTagsTap: {}
        )
    }
    .background(AppColors.backgroundGradient.ignoresSafeArea())
}
