import SwiftUI
import SwiftData

struct EditTagSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let tag: Tag

    @Query(sort: [SortDescriptor(\Tag.name)]) private var allTags: [Tag]

    @State private var name: String
    @State private var pickedColorHex: String
    @State private var showDuplicateAlert = false

    init(tag: Tag) {
        self.tag = tag
        _name = State(initialValue: tag.name)
        _pickedColorHex = State(initialValue: tag.colorHex)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("例如:开心", text: $name)
                }
                Section("颜色") {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 6)) {
                        ForEach(AppColors.customGroupPalette, id: \.self) { color in
                            let hex = color.toHexString()
                            Circle().fill(color)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle().stroke(.white, lineWidth: pickedColorHex == hex ? 3 : 0)
                                )
                                .onTapGesture { pickedColorHex = hex }
                        }
                    }
                }
            }
            .navigationTitle("编辑标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("名称已存在", isPresented: $showDuplicateAlert) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("已经有一个同名标签了，换个名字吧。")
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // 改名后不能与其他标签重名（Tag.name 是唯一约束）
        if trimmed != tag.name,
           allTags.contains(where: { $0.persistentModelID != tag.persistentModelID && $0.name == trimmed }) {
            showDuplicateAlert = true
            return
        }
        tag.name = trimmed
        tag.colorHex = pickedColorHex
        try? context.save()
        dismiss()
    }
}
