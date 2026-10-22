import Testing
import Foundation
import Speech
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

    @Test("等待麦克风权限期间调用 stop：start 放弃启动，不请求语音权限、不进入激活状态")
    func stop_duringPermissionWait_cancelsStart() async {
        var micContinuation: CheckedContinuation<Bool, Never>?
        var speechRequested = false
        let service = DictationService(
            requestMicPermission: {
                await withCheckedContinuation { micContinuation = $0 }
            },
            requestSpeechAuthorization: {
                speechRequested = true
                return .authorized
            }
        )

        let startTask = Task { @MainActor in
            try await service.start(onPartial: { _ in }, onFinal: { _ in })
        }
        // 等 start 挂起在麦克风权限上
        while micContinuation == nil { await Task.yield() }
        #expect(service.isStarting == true)
        #expect(service.isActive == false)

        service.stop()
        micContinuation?.resume(returning: true)

        var thrownCancellation = false
        do {
            try await startTask.value
        } catch is CancellationError {
            thrownCancellation = true
        } catch {}
        #expect(thrownCancellation)
        #expect(speechRequested == false)
        #expect(service.isActive == false)
        #expect(service.isStarting == false)
    }

    @Test("取消后的下一次 start 不受上一次取消影响")
    func start_afterCancelledStart_isNotCancelled() async {
        var micContinuation: CheckedContinuation<Bool, Never>?
        let service = DictationService(
            requestMicPermission: {
                await withCheckedContinuation { micContinuation = $0 }
            },
            requestSpeechAuthorization: { .denied }
        )
        let first = Task { @MainActor in try await service.start(onPartial: { _ in }, onFinal: { _ in }) }
        while micContinuation == nil { await Task.yield() }
        service.stop()
        micContinuation?.resume(returning: true)
        _ = try? await first.value

        micContinuation = nil
        let second = Task { @MainActor in try await service.start(onPartial: { _ in }, onFinal: { _ in }) }
        while micContinuation == nil { await Task.yield() }
        micContinuation?.resume(returning: true)
        // 没被取消：继续走到语音权限检查，因未授权失败
        var error: DictationService.DictationError?
        do { try await second.value } catch let e as DictationService.DictationError { error = e } catch {}
        #expect(error == .speechRecognitionDenied)
        #expect(service.isStarting == false)
    }

    @Test("麦克风未授权时 start 抛出 microphoneDenied")
    func start_micDenied_throws() async {
        let service = DictationService(
            requestMicPermission: { false },
            requestSpeechAuthorization: { .authorized }
        )
        var error: DictationService.DictationError?
        do {
            try await service.start(onPartial: { _ in }, onFinal: { _ in })
        } catch let e as DictationService.DictationError { error = e } catch {}
        #expect(error == .microphoneDenied)
        #expect(service.isActive == false)
        #expect(service.isStarting == false)
    }
}
