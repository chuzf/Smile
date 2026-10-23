import Testing
import Foundation
@testable import Smile

@Suite("ShareCenterRegistration")
@MainActor
struct ShareCenterRegistrationTests {

    @Test("重复登记只计一次，注销后计数归零")
    func register_isIdempotent_andUnregisterBalances() {
        let center = ShareInboxCenter(inbox: nil)
        let registration = ShareCenterRegistration()
        registration.register(with: center)
        registration.register(with: center)
        #expect(center.openEditorCount == 1)
        registration.unregister()
        registration.unregister()
        #expect(center.openEditorCount == 0)
    }

    @Test("没注销就被释放（相机全屏期间编辑器被一起关掉）：deinit 补做注销")
    func deinit_whileRegistered_unregisters() async {
        let center = ShareInboxCenter(inbox: nil)
        var registration: ShareCenterRegistration? = ShareCenterRegistration()
        registration?.register(with: center)
        #expect(center.openEditorCount == 1)
        registration = nil
        // deinit 里的注销排到主线程下一轮执行
        for _ in 0..<50 where center.openEditorCount != 0 { await Task.yield() }
        #expect(center.openEditorCount == 0)
    }

    @Test("已注销后再释放不会重复减计数")
    func deinit_afterUnregister_doesNotUnregisterAgain() async {
        let center = ShareInboxCenter(inbox: nil)
        let other = ShareCenterRegistration()
        other.register(with: center)
        var registration: ShareCenterRegistration? = ShareCenterRegistration()
        registration?.register(with: center)
        registration?.unregister()
        registration = nil
        for _ in 0..<50 { await Task.yield() }
        #expect(center.openEditorCount == 1)
        other.unregister()
    }
}
