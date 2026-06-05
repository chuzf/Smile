import Foundation
import LocalAuthentication

@Observable
@MainActor
final class LockSessionManager {

    private(set) var unlockedGroupIDs: Set<UUID> = []
    private(set) var unlockedEntryIDs: Set<UUID> = []

    private var groupRelockTasks: [UUID: Task<Void, Never>] = [:]
    private var entryRelockTasks: [UUID: Task<Void, Never>] = [:]

    static let unlockDuration: TimeInterval = 180

    // MARK: - Query

    func isGroupUnlocked(_ id: UUID) -> Bool { unlockedGroupIDs.contains(id) }
    func isEntryUnlocked(_ id: UUID) -> Bool { unlockedEntryIDs.contains(id) }

    // MARK: - Unlock

    @discardableResult
    func unlockGroup(_ id: UUID) async -> Bool {
        guard await authenticate(reason: "验证身份以查看储蓄罐") else { return false }
        unlockedGroupIDs.insert(id)
        scheduleGroupRelock(id: id)
        return true
    }

    @discardableResult
    func unlockEntry(_ id: UUID) async -> Bool {
        guard await authenticate(reason: "验证身份以查看锁定条目") else { return false }
        unlockedEntryIDs.insert(id)
        scheduleEntryRelock(id: id)
        return true
    }

    // MARK: - Lock all

    func lockAll() {
        groupRelockTasks.values.forEach { $0.cancel() }
        entryRelockTasks.values.forEach { $0.cancel() }
        groupRelockTasks.removeAll()
        entryRelockTasks.removeAll()
        unlockedGroupIDs.removeAll()
        unlockedEntryIDs.removeAll()
    }

    // MARK: - Auth (also called by SettingsView for export)

    func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return (try? await ctx.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )) ?? false
    }

    // MARK: - Private

    private func scheduleGroupRelock(id: UUID) {
        groupRelockTasks[id]?.cancel()
        groupRelockTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(LockSessionManager.unlockDuration))
            } catch {
                return
            }
            self?.unlockedGroupIDs.remove(id)
            self?.groupRelockTasks.removeValue(forKey: id)
        }
    }

    private func scheduleEntryRelock(id: UUID) {
        entryRelockTasks[id]?.cancel()
        entryRelockTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(LockSessionManager.unlockDuration))
            } catch {
                return
            }
            self?.unlockedEntryIDs.remove(id)
            self?.entryRelockTasks.removeValue(forKey: id)
        }
    }
}
