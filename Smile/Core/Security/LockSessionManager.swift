import Foundation
import LocalAuthentication

@Observable
@MainActor
final class LockSessionManager {

    private(set) var unlockedGroupIDs: Set<UUID> = []
    private(set) var unlockedEntryIDs: Set<UUID> = []

    /// 有解锁内容时离开前台，整窗口盖上遮罩，防止多任务快照和回到前台时露出加锁内容
    private(set) var isShielded = false
    /// 进过后台再回来，要重新验证身份才能撤掉遮罩
    private(set) var needsReauth = false
    /// 放弃验证、全部上锁时加一；正在展示加锁内容的页面据此退出
    private(set) var relockEpoch = 0
    /// 遮罩显隐变化时通知外部（由 App 挂上整窗口遮罩）
    @ObservationIgnored var onShieldChange: ((Bool) -> Void)?

    private var groupRelockTasks: [UUID: Task<Void, Never>] = [:]
    private var entryRelockTasks: [UUID: Task<Void, Never>] = [:]
    private var authInProgress = false
    private var stashedGroupIDs: Set<UUID> = []
    private var stashedEntryIDs: Set<UUID> = []
    private var autoAuthPending = false
    @ObservationIgnored private let authenticator: (String) async -> Bool

    static let unlockDuration: TimeInterval = 180

    init(authenticator: ((String) async -> Bool)? = nil) {
        self.authenticator = authenticator ?? LockSessionManager.deviceOwnerAuthentication
    }

    var hasUnlockedContent: Bool { !unlockedGroupIDs.isEmpty || !unlockedEntryIDs.isEmpty }

    /// 正在展示加锁内容的页面（解锁计时到期后页面仍可能开着，所以不能只看解锁集合）
    private(set) var lockedContentDisplays: Set<UUID> = []

    /// 离开前台时是否需要遮罩
    var needsPrivacyProtection: Bool { hasUnlockedContent || !lockedContentDisplays.isEmpty }

    func beginDisplayingLockedContent(_ token: UUID) { lockedContentDisplays.insert(token) }
    func endDisplayingLockedContent(_ token: UUID) { lockedContentDisplays.remove(token) }

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
        relockEpoch += 1
    }

    // MARK: - Scene phase / privacy shield

    /// 进入 inactive（上滑多任务、下拉控制中心）：有解锁内容就先盖上
    func sceneWillResignActive() {
        // 自己弹出的 Face ID 也会让 App 进入 inactive，这时不盖
        guard !authInProgress, needsPrivacyProtection else { return }
        setShielded(true)
    }

    /// 进入后台：记下已解锁的内容，回来时验证通过再原样恢复（不直接关页面，编辑中的草稿不丢）
    func sceneDidEnterBackground() {
        guard needsPrivacyProtection else { return }
        stashedGroupIDs.formUnion(unlockedGroupIDs)
        stashedEntryIDs.formUnion(unlockedEntryIDs)
        needsReauth = true
        autoAuthPending = true
        setShielded(true)
    }

    func sceneDidBecomeActive() {
        guard needsReauth else {
            setShielded(false)
            return
        }
        // 只在从后台回来时自动弹一次验证；用户取消后不再反复弹，由遮罩上的按钮重试
        if autoAuthPending {
            autoAuthPending = false
            Task { await resumeFromShield() }
        }
    }

    /// 遮罩上的「解锁」：验证通过则恢复进后台前的解锁状态
    @discardableResult
    func resumeFromShield() async -> Bool {
        guard needsReauth else { return true }
        guard await authenticate(reason: "验证身份以继续查看") else { return false }
        for id in stashedGroupIDs {
            unlockedGroupIDs.insert(id)
            scheduleGroupRelock(id: id)
        }
        for id in stashedEntryIDs {
            unlockedEntryIDs.insert(id)
            scheduleEntryRelock(id: id)
        }
        clearShieldState()
        return true
    }

    /// 遮罩上的「返回首页」：放弃验证，全部上锁，展示加锁内容的页面随之退出
    func abandonShield() {
        clearShieldState()
        lockAll()
    }

    private func clearShieldState() {
        stashedGroupIDs.removeAll()
        stashedEntryIDs.removeAll()
        needsReauth = false
        autoAuthPending = false
        setShielded(false)
    }

    private func setShielded(_ value: Bool) {
        guard isShielded != value else { return }
        isShielded = value
        onShieldChange?(value)
    }

    // MARK: - Auth (also called by SettingsView for export)

    func authenticate(reason: String) async -> Bool {
        guard !authInProgress else { return false }
        authInProgress = true
        defer { authInProgress = false }
        return await authenticator(reason)
    }

    private static func deviceOwnerAuthentication(reason: String) async -> Bool {
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
