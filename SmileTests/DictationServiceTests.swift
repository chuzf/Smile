import Testing
import Foundation
@testable import Smile

@Suite("DictationService")
@MainActor
struct DictationServiceTests {

    @Test("初始状态 isActive 为 false")
    func initialState_isNotActive() {
        let service = DictationService()
        #expect(service.isActive == false)
    }

    @Test("初始状态 error 为 nil")
    func initialState_errorIsNil() {
        let service = DictationService()
        #expect(service.error == nil)
    }

    @Test("未激活时调用 stop 不崩溃且 isActive 保持 false")
    func stop_whenNotActive_isNoOp() {
        let service = DictationService()
        service.stop()
        #expect(service.isActive == false)
    }
}
