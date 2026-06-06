import SwiftUI

struct EditGroupSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(LockSessionManager.self) private var lockSession

    @Bindable var group: Group

    @State private var name: String
    @State private var pickedColorHex: String
    @State private var pickedSymbol: String
    @State private var localIsLocked: Bool
    @State private var isAuthenticating = false

    private let symbols = ["heart", "leaf", "star", "moon", "sun.max",
                           "cup.and.saucer", "house", "figure.walk", "music.note"]

    init(group: Group) {
        self.group = group
        _name = State(initialValue: group.name)
        _pickedColorHex = State(initialValue: group.colorHex)
        _pickedSymbol = State(initialValue: group.iconSymbol)
        _localIsLocked = State(initialValue: group.isLocked)
    }

    private var lockedToggleBinding: Binding<Bool> {
        Binding(
            get: { localIsLocked },
            set: { newValue in
                guard !isAuthenticating else { return }
                if localIsLocked && !newValue {
                    // 解锁方向：需要认证，不立即修改状态，认证成功后再改
                    isAuthenticating = true
                    Task {
                        if await lockSession.authenticate(reason: "验证身份以解锁储蓄罐") {
                            localIsLocked = false
                        }
                        isAuthenticating = false
                    }
                } else {
                    // 加锁方向：直接允许
                    localIsLocked = newValue
                }
            }
        )
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
                if !group.isBuiltIn {
                    Section {
                        Toggle(isOn: lockedToggleBinding) {
                            Label("锁定此储蓄罐", systemImage: "lock.fill")
                        }
                        .tint(AppColors.warmOrange)
                        .disabled(isAuthenticating)
                    } footer: {
                        Text("开启后需通过 Face ID 或密码才能查看内容")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        group.colorHex = pickedColorHex
        group.iconSymbol = pickedSymbol
        group.isLocked = localIsLocked
        try? context.save()
        dismiss()
    }
}
