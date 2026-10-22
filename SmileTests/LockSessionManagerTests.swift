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

    @Test("没有解锁内容时离开前台不盖遮罩")
    func noShieldWithoutUnlockedContent() {
        let mgr = LockSessionManager(authenticator: { _ in true })
        mgr.sceneWillResignActive()
        mgr.sceneDidEnterBackground()
        #expect(mgr.isShielded == false)
        #expect(mgr.needsReauth == false)
    }

    @Test("inactive 后直接回到前台，遮罩撤掉且不需验证")
    func inactiveThenActiveRemovesShield() async {
        let mgr = LockSessionManager(authenticator: { _ in true })
        let id = UUID()
        await mgr.unlockGroup(id)
        mgr.sceneWillResignActive()
        #expect(mgr.isShielded)
        mgr.sceneDidBecomeActive()
        #expect(mgr.isShielded == false)
        #expect(mgr.isGroupUnlocked(id))
    }

    @Test("进过后台：验证通过后恢复解锁状态")
    func backgroundThenReauthRestores() async {
        var allow = true
        let mgr = LockSessionManager(authenticator: { _ in allow })
        let g = UUID(), e = UUID()
        await mgr.unlockGroup(g)
        await mgr.unlockEntry(e)
        mgr.sceneWillResignActive()
        mgr.sceneDidEnterBackground()
        #expect(mgr.isShielded && mgr.needsReauth)

        allow = false
        #expect(await mgr.resumeFromShield() == false)
        #expect(mgr.isShielded)

        allow = true
        #expect(await mgr.resumeFromShield())
        #expect(mgr.isShielded == false)
        #expect(mgr.isGroupUnlocked(g) && mgr.isEntryUnlocked(e))
    }

    @Test("放弃验证：全部上锁并通知页面退出")
    func abandonLocksEverything() async {
        let mgr = LockSessionManager(authenticator: { _ in true })
        let g = UUID()
        await mgr.unlockGroup(g)
        mgr.sceneDidEnterBackground()
        let epoch = mgr.relockEpoch
        mgr.abandonShield()
        #expect(mgr.isShielded == false)
        #expect(mgr.isGroupUnlocked(g) == false)
        #expect(mgr.relockEpoch == epoch + 1)
    }

    @Test("遮罩显隐变化会回调")
    func shieldCallbackFires() async {
        let mgr = LockSessionManager(authenticator: { _ in true })
        var events: [Bool] = []
        mgr.onShieldChange = { events.append($0) }
        await mgr.unlockEntry(UUID())
        mgr.sceneWillResignActive()
        mgr.sceneDidBecomeActive()
        #expect(events == [true, false])
    }
}
