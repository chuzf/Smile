import SwiftUI

struct EditGroupSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Bindable var group: Group

    @State private var name: String
    @State private var pickedColorHex: String
    @State private var pickedSymbol: String

    private let symbols = ["heart", "leaf", "star", "moon", "sun.max",
                           "cup.and.saucer", "house", "figure.walk", "music.note"]

    init(group: Group) {
        self.group = group
        _name = State(initialValue: group.name)
        _pickedColorHex = State(initialValue: group.colorHex)
        _pickedSymbol = State(initialValue: group.iconSymbol)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("例如:家人", text: $name)
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
                Section("图标") {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 5)) {
                        ForEach(symbols, id: \.self) { sym in
                            Image(systemName: sym)
                                .font(.system(size: 20))
                                .frame(width: 36, height: 36)
                                .background(
                                    Circle().fill(
                                        pickedSymbol == sym ? AppColors.warmOrange.opacity(0.3) : Color.clear
                                    )
                                )
                                .onTapGesture { pickedSymbol = sym }
                        }
                    }
                }
                Section {
                    Toggle(isOn: $group.isLocked) {
                        Label("锁定此储蓄罐", systemImage: "lock.fill")
                    }
                    .tint(AppColors.warmOrange)
                } footer: {
                    Text("开启后需通过 Face ID 或密码才能查看内容")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("编辑分组")
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
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        group.name = trimmed
        group.colorHex = pickedColorHex
        group.iconSymbol = pickedSymbol
        try? context.save()
        dismiss()
    }
}
