# Custom Group Edit Sheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the inline rename in 「我」tab with a swipe-left gesture that reveals 编辑 and 删除 buttons; tapping 编辑 opens a full edit sheet pre-filled with the group's current name, color, and icon, where the user can modify any field and tap 保存.

**Architecture:** Two-file change. A new `EditGroupSheet` mirrors `AddGroupSheet` but receives an existing `Group` object, pre-populates all fields from it via `init(group:)`, and saves mutations back to the same SwiftData object on confirm. `MeTabView` is reverted to simple row rendering and gains per-row `.swipeActions` with an edit trigger (opens the sheet) and a delete action with a blocked-alert fallback.

**Tech Stack:** SwiftUI, SwiftData

---

### Task 1: Create EditGroupSheet

**Files:**
- Create: `SmileJar/Features/Home/EditGroupSheet.swift`

- [ ] **Step 1: Create the file**

  Create `/Users/chuzhanfeng/work/claude/smile/SmileJar/Features/Home/EditGroupSheet.swift` with:

  ```swift
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
  ```

  Note: `toHexString()` and `Color(hex:)` are already defined elsewhere in the module (`AddGroupSheet.swift` and `AppColors.swift`), no import needed.

- [ ] **Step 2: Build to verify**

  ```
  xcodebuild -project /Users/chuzhanfeng/work/claude/smile/SmileJar.xcodeproj -scheme SmileJar -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5
  ```

  Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

  ```bash
  git -C /Users/chuzhanfeng/work/claude/smile add SmileJar/Features/Home/EditGroupSheet.swift
  git -C /Users/chuzhanfeng/work/claude/smile commit -m "feat: add EditGroupSheet for editing custom group name/color/icon"
  ```

---

### Task 2: Update MeTabView — swipe actions with edit and delete

**Files:**
- Modify: `SmileJar/Features/Me/MeTabView.swift`

- [ ] **Step 1: Replace entire file content**

  Overwrite `/Users/chuzhanfeng/work/claude/smile/SmileJar/Features/Me/MeTabView.swift` with:

  ```swift
  import SwiftUI
  import SwiftData

  struct MeTabView: View {
      @Environment(\.modelContext) private var context
      @Query(sort: [SortDescriptor(\Group.sortOrder)]) private var groups: [Group]

      @State private var globalSearch = ""
      @State private var editingGroup: Group? = nil
      @State private var deleteBlockedGroup: Group? = nil

      var body: some View {
          NavigationStack {
              List {
                  Section {
                      HStack {
                          Image(systemName: "magnifyingglass")
                              .foregroundStyle(AppColors.textSecondary)
                          TextField("全局搜索所有记录", text: $globalSearch)
                      }
                  }
                  if !globalSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                      Section("搜索结果") {
                          let results = (try? SearchService.search(in: context, query: globalSearch, group: nil)) ?? []
                          if results.isEmpty {
                              Text("没找到匹配的记录").foregroundStyle(AppColors.textSecondary)
                          } else {
                              ForEach(results) { e in
                                  NavigationLink {
                                      EntryDetailView(entry: e)
                                  } label: {
                                      VStack(alignment: .leading) {
                                          Text(e.title.isEmpty ? "(无标题)" : e.title)
                                          Text(e.group?.name ?? "—")
                                              .font(.caption)
                                              .foregroundStyle(AppColors.textSecondary)
                                      }
                                  }
                              }
                          }
                      }
                  }

                  Section("分组管理") {
                      ForEach(groups) { g in
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
                              }
                          }
                          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                              if !g.isBuiltIn {
                                  Button(role: .destructive) {
                                      if g.canDelete {
                                          context.delete(g)
                                          try? context.save()
                                      } else {
                                          deleteBlockedGroup = g
                                      }
                                  } label: {
                                      Label("删除", systemImage: "trash")
                                  }
                                  Button {
                                      editingGroup = g
                                  } label: {
                                      Label("编辑", systemImage: "pencil")
                                  }
                                  .tint(.blue)
                              }
                          }
                      }
                  }

                  Section("设置") {
                      NavigationLink {
                          SettingsView()
                      } label: {
                          Label("App 设置", systemImage: "gearshape")
                      }
                  }
              }
              .navigationTitle("我")
              .sheet(item: $editingGroup) { group in
                  EditGroupSheet(group: group)
              }
              .alert("无法删除", isPresented: Binding(
                  get: { deleteBlockedGroup != nil },
                  set: { if !$0 { deleteBlockedGroup = nil } }
              )) {
                  Button("好的", role: .cancel) { deleteBlockedGroup = nil }
              } message: {
                  Text("储蓄罐里还有内容，请先清空再删除。")
              }
          }
      }
  }
  ```

- [ ] **Step 2: Build to verify**

  ```
  xcodebuild -project /Users/chuzhanfeng/work/claude/smile/SmileJar.xcodeproj -scheme SmileJar -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5
  ```

  Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run tests**

  ```
  xcodebuild test -project /Users/chuzhanfeng/work/claude/smile/SmileJar.xcodeproj -scheme SmileJar -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
  ```

  Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

  ```bash
  git -C /Users/chuzhanfeng/work/claude/smile add SmileJar/Features/Me/MeTabView.swift
  git -C /Users/chuzhanfeng/work/claude/smile commit -m "feat: swipe-left on custom groups to edit or delete in 我 tab

  Replace inline rename with swipe actions: left-swipe on a
  custom group row reveals 编辑 (opens EditGroupSheet) and
  删除 (deletes if empty, shows alert if not). Built-in groups
  have no swipe actions."
  ```
