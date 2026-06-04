import Foundation
import Testing
@testable import Smile

@Suite("LockSessionManager")
@MainActor
struct LockSessionManagerTests {

    @Test("初始状态：所有 ID 均未解锁")
    func initialStateAllLocked() {
        let mgr = LockSessionManager()
        let id = UUID()
        #expect(mgr.isGroupUnlocked(id) == false)
        #expect(mgr.isEntryUnlocked(id) == false)
    }

    @Test("lockAll 在空状态下安全执行")
    func lockAllOnEmpty() {
        let mgr = LockSessionManager()
        mgr.lockAll()
        #expect(mgr.isGroupUnlocked(UUID()) == false)
        #expect(mgr.isEntryUnlocked(UUID()) == false)
    }

    @Test("unlockDuration 为 180 秒")
    func unlockDurationIs180() {
        #expect(LockSessionManager.unlockDuration == 180)
    }
}
