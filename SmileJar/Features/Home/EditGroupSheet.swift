import SwiftUI

struct EditGroupSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var group: Group

    @State private var name: String
    @State private var pickedColor: Color
    @State private var pickedSymbol: String

    private let symbols = ["heart", "leaf", "star", "moon", "sun.max",
                           "cup.and.saucer", "house", "figure.walk", "music.note"]

    init(group: Group) {
        self.group = group
        _name = State(initialValue: group.name)
        _pickedColor = State(initialValue: Color(hex: group.colorHex))
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
                            Circle().fill(color)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle().stroke(.white, lineWidth: pickedColor == color ? 3 : 0)
                                )
                                .onTapGesture { pickedColor = color }
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
        group.colorHex = pickedColor.toHexString()
        group.iconSymbol = pickedSymbol
        try? context.save()
        dismiss()
    }
}
