import SwiftUI
import SwiftData

struct GroupNavigation: Identifiable, Equatable, Hashable {
    let id: UUID
    let highlightEntryID: UUID?

    init(groupID: UUID, highlightEntryID: UUID? = nil) {
        id = groupID
        self.highlightEntryID = highlightEntryID
    }
}

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(LockSessionManager.self) private var lockSession

    @Query(filter: #Predicate<Group> { $0.isBuiltIn == true },
           sort: [SortDescriptor(\Group.sortOrder)])
    private var builtinGroups: [Group]

    @Query(filter: #Predicate<Group> { $0.isBuiltIn == false },
           sort: [SortDescriptor(\Group.sortOrder)])
    private var customGroups: [Group]

    @Binding var externalNav: GroupNavigation?
    @State private var activeNav: GroupNavigation?
    @State private var showAddGroup = false
    @State private var deleteBlockedGroup: Group?

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundGradient.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.dateGreeting())
                                .font(.system(size: 12))
                                .foregroundStyle(AppColors.textSecondary)
                            Text("我的储蓄罐")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(AppColors.textPrimary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 10)

                        if builtinGroups.isEmpty {
                            EmptyStateView(
                                icon: "exclamationmark.bubble",
                                message: "应用初始化中,请稍候……"
                            )
                            .padding(.top, 60)
                        }

                        ForEach(builtinGroups) { jarCard($0) }

                        ForEach(customGroups) { group in
                            jarCard(group)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        if group.canDelete {
                                            context.delete(group)
                                            try? context.save()
                                        } else {
                                            deleteBlockedGroup = group
                                        }
                                    } label: {
                                        Label("删除储蓄罐", systemImage: "trash")
                                    }
                                }
                        }

                        Button {
                            showAddGroup = true
                        } label: {
                            HStack {
                                Image(systemName: "plus")
                                Text("添加储蓄罐")
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(AppColors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18)
                        .padding(.top, 6)
                    }
                    .padding(.bottom, 30)
                }
            }
            .navigationDestination(item: $activeNav) { nav in
                if let group = (builtinGroups + customGroups).first(where: { $0.id == nav.id }) {
                    GroupDetailView(group: group, highlightEntryID: nav.highlightEntryID)
                }
            }
            .onChange(of: externalNav) { _, nav in
                guard let nav else { return }
                activeNav = nav
                externalNav = nil
            }
            .sheet(isPresented: $showAddGroup) {
                AddGroupSheet()
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

    @ViewBuilder
    private func jarCard(_ group: Group) -> some View {
        let locked = group.isLocked && !lockSession.isGroupUnlocked(group.id)
        JarCardView(
            group: group,
            recentEntry: mostRecent(in: group),
            isLocked: locked
        ) {
            handleJarTap(group)
        }
        .padding(.horizontal, 14)
    }

    private func handleJarTap(_ group: Group) {
        Task { @MainActor in
            if group.isLocked && !lockSession.isGroupUnlocked(group.id) {
                guard await lockSession.unlockGroup(group.id) else { return }
            }
            activeNav = GroupNavigation(groupID: group.id)
        }
    }

    private func mostRecent(in group: Group) -> Entry? {
        group.entries.max(by: { $0.createdAt < $1.createdAt })
    }

    private static func dateGreeting() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: .now)
    }
}
