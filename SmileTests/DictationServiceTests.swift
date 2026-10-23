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

    @Test("等待权限期间 isInProgress 为 true：此时再点麦克风应当取消，而不是开始新的一轮")
    func isInProgress_duringPermissionWait_isTrue() async {
        var micContinuation: CheckedContinuation<Bool, Never>?
        let service = DictationService(
            requestMicPermission: {
                await withCheckedContinuation { micContinuation = $0 }
            },
            requestSpeechAuthorization: { .authorized }
        )
        #expect(service.isInProgress == false)

        let startTask = Task { @MainActor in
            try await service.start(onPartial: { _ in }, onFinal: { _ in })
        }
        while micContinuation == nil { await Task.yield() }
        // 编辑器的口述按钮按 isInProgress 判断：还没打开麦克风（isActive 为 false）也要当作「停止」
        #expect(service.isActive == false)
        #expect(service.isInProgress == true)

        // 第二次点按：取消启动
        service.stop()
        micContinuation?.resume(returning: true)
        var cancelled = false
        do { try await startTask.value } catch is CancellationError { cancelled = true } catch {}
        #expect(cancelled)
        #expect(service.isInProgress == false)
    }

    @Test("输入格式采样率或声道数为 0（麦克风被占用）时不可用于 installTap")
    func isUsableInputFormat_rejectsZeroRateOrChannels() {
        #expect(DictationService.isUsableInputFormat(sampleRate: 48_000, channelCount: 1))
        #expect(!DictationService.isUsableInputFormat(sampleRate: 0, channelCount: 1))
        #expect(!DictationService.isUsableInputFormat(sampleRate: 48_000, channelCount: 0))
        #expect(!DictationService.isUsableInputFormat(sampleRate: 0, channelCount: 0))
    }
}
