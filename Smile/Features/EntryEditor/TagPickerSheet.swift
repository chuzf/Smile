import SwiftUI
import SwiftData

struct TagPickerSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\Tag.name)]) private var allTags: [Tag]
    @Binding var selected: Set<PersistentIdentifier>

    @State private var newTagName: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section("选择标签") {
                    if allTags.isEmpty {
                        Text("还没有标签,下面输入新建")
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    ForEach(allTags) { tag in
                        Button {
                            toggle(tag)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(hex: tag.colorHex))
                                    .frame(width: 10, height: 10)
                                Text(tag.name)
                                    .foregroundStyle(AppColors.textPrimary)
                                Spacer()
                                if selected.contains(tag.persistentModelID) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppColors.warmOrange)
                                }
                            }
                        }
                    }
                }
                Section("新建标签") {
                    HStack {
                        TextField("名称", text: $newTagName)
                        Button("添加") { createTag() }
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func toggle(_ tag: Tag) {
        if selected.contains(tag.persistentModelID) {
            selected.remove(tag.persistentModelID)
        } else {
            selected.insert(tag.persistentModelID)
        }
    }

    private func createTag() {
        let trimmed = newTagName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !allTags.contains(where: { $0.name == trimmed }) else { return }
        let randomColor = AppColors.customGroupPalette.randomElement() ?? .gray
        let tag = Tag(name: trimmed, colorHex: randomColor.toHexString())
        context.insert(tag)
        try? context.save()
        selected.insert(tag.persistentModelID)
        newTagName = ""
    }
}
