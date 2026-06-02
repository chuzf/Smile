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
    private var isStarting = false

    func start(
        onPartial: @escaping @MainActor (String) -> Void,
        onFinal:   @escaping @MainActor (String) -> Void
    ) async throws {
        guard !isActive, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        error = nil

        // 1. 麦克风权限
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else { throw DictationError.microphoneDenied }

        // 2. 语音识别权限
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            capturedRequest.append(buffer)
        }

        // 7. 识别任务
        recognitionTask = rec.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.cleanupAudio()
                    self.isActive = false
                    // Don't surface cancellation errors — they're triggered by stop()
                    let nsError = error as NSError
                    let isCancellation = nsError.code == NSUserCancelledError
                    if !isCancellation {
                        self.error = .recognitionFailed(error)
                    }
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

    func stop() {
        guard isActive else { return }
        cleanupAudio()
        isActive = false
    }

    private func cleanupAudio() {
        let taskToCancel = recognitionTask
        recognitionTask = nil   // nil first to prevent re-entry from cancel callback
        taskToCancel?.cancel()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognizer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
