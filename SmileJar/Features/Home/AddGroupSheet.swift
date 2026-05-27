import SwiftUI
import UIKit

struct AddGroupSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var pickedColor: Color = AppColors.customGroupPalette[0]
    @State private var pickedSymbol: String = "heart"

    private let symbols = ["heart", "leaf", "star", "moon", "sun.max",
                           "cup.and.saucer", "house", "figure.walk", "music.note"]

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
            .navigationTitle("新建分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let colorHex = pickedColor.toHexString()
        let group = Group(
            name: trimmed,
            iconSymbol: pickedSymbol,
            colorHex: colorHex,
            isBuiltIn: false,
            sortOrder: 100
        )
        context.insert(group)
        try? context.save()
        dismiss()
    }
}

extension Color {
    func toHexString() -> String {
        let uic = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uic.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
