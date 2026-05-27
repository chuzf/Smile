# Custom Group Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow custom groups (isBuiltIn == false) to be renamed inline in the 「我」tab's group management section, via a pencil icon that switches the row to an editable TextField; built-in groups show a lock icon and cannot be renamed.

**Architecture:** All changes are contained in `MeTabView.swift`. Three `@State`/`@FocusState` variables track which group is being edited and the draft name. The ForEach row renders either a read-only row (with pencil icon for custom groups) or an edit row (TextField + confirm/cancel buttons). Saving writes directly to the SwiftData model context.

**Tech Stack:** SwiftUI, SwiftData, `@FocusState`

---

### Task 1: Add Inline Rename to MeTabView

**Files:**
- Modify: `SmileJar/Features/Me/MeTabView.swift`

- [ ] **Step 1: Add state variables and helper methods**

  Open `SmileJar/Features/Me/MeTabView.swift`. After the existing `@State private var globalSearch = ""` line, add:

  ```swift
  @State private var editingGroupID: UUID? = nil
  @State private var draftName: String = ""
  @FocusState private var isEditFocused: Bool
  ```

  At the bottom of the struct (after `deleteCustom`), add these three methods:

  ```swift
  private func startEdit(_ group: Group) {
      draftName = group.name
      editingGroupID = group.id
      isEditFocused = true
  }

  private func commitEdit(for group: Group) {
      let trimmed = draftName.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { return }
      group.name = trimmed
      try? context.save()
      cancelEdit()
  }

  private func cancelEdit() {
      editingGroupID = nil
      draftName = ""
      isEditFocused = false
  }
  ```

- [ ] **Step 2: Replace the ForEach content in the 分组管理 Section**

  Find the `Section("分组管理")` block and replace the entire `ForEach` body so each row is either an edit row or a normal row:

  ```swift
  Section("分组管理") {
      ForEach(groups) { g in
          if editingGroupID == g.id {
              HStack {
                  Image(systemName: g.iconSymbol)
                      .foregroundStyle(Color(hex: g.colorHex))
                  TextField("分组名称", text: $draftName)
                      .focused($isEditFocused)
                      .onSubmit { commitEdit(for: g) }
                  Spacer()
                  Button { cancelEdit() } label: {
                      Image(systemName: "xmark.circle.fill")
                          .foregroundStyle(AppColors.textSecondary)
                  }
                  .buttonStyle(.plain)
                  Button { commitEdit(for: g) } label: {
                      Image(systemName: "checkmark.circle.fill")
                          .foregroundStyle(AppColors.warmOrange)
                  }
                  .buttonStyle(.plain)
                  .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
              }
              .deleteDisabled(true)
          } else {
              HStack {
                  Image(systemName: g.iconSymbol)
                      .foregroundStyle(Color(hex: g.colorHex))
                  Text(g.name)
                  Spacer()
                  Text("\(g.entries.count)")
                      .foregroundStyle(AppColors.textSecondary)
                  if g.isBuiltIn {
                      Image(systemName: "lock.fill")
                          .font(.caption)
                          .foregroundStyle(AppColors.textSecondary)
                  } else {
                      Button { startEdit(g) } label: {
                          Image(systemName: "pencil")
                              .foregroundStyle(AppColors.textSecondary)
                      }
                      .buttonStyle(.plain)
                  }
              }
              .deleteDisabled(!g.canDelete)
          }
      }
      .onDelete(perform: deleteCustom)
  }
  ```

- [ ] **Step 3: Build and verify**

  In Xcode, press `Cmd+B` to build. Expected: build succeeds with no errors or warnings.

  Then run the app on simulator. Verify:
  1. In 「我」tab → 分组管理: built-in groups (微笑储蓄罐, 优势储蓄罐) show a lock icon, no pencil
  2. Custom groups show a pencil icon on the right
  3. Tapping pencil → row switches to TextField pre-filled with current name, keyboard appears
  4. Editing name and tapping ✓ (or pressing Return) saves the new name
  5. Tapping ✗ discards the change and returns to normal row
  6. Checkmark button is disabled when TextField is empty
  7. The renamed group name updates immediately in HomeView jar cards

- [ ] **Step 4: Commit**

  ```bash
  git add SmileJar/Features/Me/MeTabView.swift
  git commit -m "feat: inline rename for custom groups in 我 tab

  Pencil icon on each custom group row opens inline TextField.
  Confirm saves to SwiftData; cancel discards. Built-in groups
  remain read-only (lock icon, no pencil)."
  ```
