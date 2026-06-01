import Foundation
import Speech

actor TranscriptionService {

    enum TranscriptionError: Error {
        case authorizationDenied
        case recognizerUnavailable
        case recognitionFailed(Error)
    }

    /// 异步请求权限。返回是否已授权。
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// 转写本地音频文件
    /// - Parameter url: 本地 .m4a 路径
    /// - Returns: 转写文本(中文)
    func transcribe(audioURL: URL) async throws -> String {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw TranscriptionError.authorizationDenied
        }
        let locale = Locale(identifier: "zh-CN")
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { cont in
            // Capture recognizer to keep it alive for the duration of the task.
            recognizer.recognitionTask(with: request) { [recognizer] result, error in
                _ = recognizer  // retain until callback fires
                if let error = error {
                    cont.resume(throwing: TranscriptionError.recognitionFailed(error))
                } else if let result = result {
                    if result.isFinal {
                        cont.resume(returning: result.bestTranscription.formattedString)
                    }
                    // partial result: wait for isFinal
                } else {
                    // nil result + nil error: recognition ended with no output
                    cont.resume(returning: "")
                }
            }
        }
    }
}
