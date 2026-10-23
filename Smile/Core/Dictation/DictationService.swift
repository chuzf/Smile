import AVFoundation
import Speech

@Observable @MainActor final class DictationService {

    enum DictationError: Error, LocalizedError, Equatable {
        case microphoneDenied
        case speechRecognitionDenied
        case recognizerUnavailable
        case recognitionFailed(Error)

        static func == (lhs: DictationError, rhs: DictationError) -> Bool {
            switch (lhs, rhs) {
            case (.microphoneDenied, .microphoneDenied),
                 (.speechRecognitionDenied, .speechRecognitionDenied),
                 (.recognizerUnavailable, .recognizerUnavailable),
                 (.recognitionFailed, .recognitionFailed):
                return true
            default:
                return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "需要麦克风权限，请前往「设置」>「隐私与安全性」>「麦克风」开启"
            case .speechRecognitionDenied:
                return "需要语音识别权限，请前往「设置」>「隐私与安全性」>「语音识别」开启"
            case .recognizerUnavailable:
                return "语音识别暂时不可用，请稍后再试"
            case .recognitionFailed(let e):
                return "识别失败：\(e.localizedDescription)"
            }
        }
    }

    private(set) var isActive = false
    private(set) var error: DictationError?

    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    /// start() 正在等待权限等异步步骤，麦克风尚未打开
    private(set) var isStarting = false
    /// start() 还在等待期间调用了 stop()：start 在每个 await 之后检查，放弃打开麦克风
    private var isStartCancelled = false
    /// tap 是否已安装；引擎启动失败时引擎没在运行，但 tap 仍在，必须单独记录才能移除
    private var isTapInstalled = false

    /// 口述进行中或正在启动（等待权限）。此时再点麦克风应当停止 / 取消，而不是开始新的一轮
    var isInProgress: Bool { isActive || isStarting }
    private var currentSession: UUID?

    private let requestMicPermission: @MainActor () async -> Bool
    private let requestSpeechAuthorization: @MainActor () async -> SFSpeechRecognizerAuthorizationStatus

    /// 权限请求可注入，便于测试启动过程中被取消的情况
    init(
        requestMicPermission: @escaping @MainActor () async -> Bool = {
            await AVAudioApplication.requestRecordPermission()
        },
        requestSpeechAuthorization: @escaping @MainActor () async -> SFSpeechRecognizerAuthorizationStatus = {
            await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
        }
    ) {
        self.requestMicPermission = requestMicPermission
        self.requestSpeechAuthorization = requestSpeechAuthorization
    }

    func start(
        onPartial: @escaping @MainActor (String) -> Void,
        onFinal:   @escaping @MainActor (String) -> Void
    ) async throws {
        guard !isActive, !isStarting else { return }
        isStarting = true
        isStartCancelled = false
        defer {
            isStarting = false
            isStartCancelled = false
        }
        error = nil

        // 1. 麦克风权限
        let micGranted = await requestMicPermission()
        try checkStartCancelled()
        guard micGranted else { throw DictationError.microphoneDenied }

        // 2. 语音识别权限
        let speechStatus = await requestSpeechAuthorization()
        try checkStartCancelled()
        guard speechStatus == .authorized else { throw DictationError.speechRecognitionDenied }

        // 3. 识别器
        let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        guard let rec, rec.isAvailable else { throw DictationError.recognizerUnavailable }
        recognizer = rec

        // 4. 音频会话
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // 5. 识别请求
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        // 6. 音频采集 — 捕获 request 引用避免跨 actor 访问
        let capturedRequest = request
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // 麦克风被通话或其它 App 占用时输入格式的采样率 / 声道数为 0，用它 installTap 会抛 Objective-C 异常直接崩溃
        guard Self.isUsableInputFormat(sampleRate: format.sampleRate, channelCount: format.channelCount) else {
            cleanupAudio()
            throw DictationError.recognizerUnavailable
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            capturedRequest.append(buffer)
        }
        isTapInstalled = true

        // 7. 识别任务
        // 每轮口述一个标识：旧任务被 cancel 后迟到的回调不能清理或改动新一轮的状态
        let sessionID = UUID()
        currentSession = sessionID
        recognitionTask = rec.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.currentSession == sessionID else { return }
                if let error {
                    // If isActive is already false, stop() was called before this callback
                    // fired — this error is the expected cancellation from our own cleanup.
                    guard self.isActive else { return }
                    self.cleanupAudio()
                    self.isActive = false
                    self.error = .recognitionFailed(error)
                    return
                }
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.cleanupAudio()
                    self.isActive = false
                    onFinal(text)
                } else {
                    onPartial(text)
                }
            }
        }

        // 8. 启动引擎
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cleanupAudio()
            throw error
        }
        isActive = true
    }

    /// 停止口述。start() 还在等待权限时调用也有效：标记取消，start 醒来后不会打开麦克风
    func stop() {
        if isStarting { isStartCancelled = true }
        guard isActive else { return }
        cleanupAudio()
        isActive = false
    }

    /// 输入格式能否用于 installTap：采样率和声道数都必须大于 0
    nonisolated static func isUsableInputFormat(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

    private func checkStartCancelled() throws {
        if isStartCancelled { throw CancellationError() }
    }

    private func cleanupAudio() {
        let taskToCancel = recognitionTask
        recognitionTask = nil   // nil first to prevent re-entry from cancel callback
        taskToCancel?.cancel()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognizer = nil
        currentSession = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        // 引擎启动失败时 isRunning 为 false 但 tap 仍在；不移除的话下次 installTap 会断言崩溃
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
