import SwiftUI
import AVFoundation

struct VoiceRecorderView: View {
    @Environment(\.dismiss) var dismiss
    let entryDraftID: UUID
    let onFinished: (DraftAttachment) -> Void

    @State private var recorder: AVAudioRecorder?
    @State private var isRecording = false
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var recordedURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 88))
                    .foregroundStyle(isRecording ? Color.red : AppColors.warmOrange)
                Text(String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                    .font(.system(size: 28, weight: .light, design: .monospaced))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                HStack(spacing: 40) {
                    if isRecording {
                        Button {
                            stopRecording(save: false)
                            dismiss()
                        } label: {
                            Label("取消", systemImage: "xmark.circle.fill")
                                .font(.system(size: 18))
                        }
                        .foregroundStyle(.gray)

                        Button {
                            stopRecording(save: true)
                        } label: {
                            Label("完成", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 18))
                        }
                        .foregroundStyle(AppColors.warmOrange)
                    } else {
                        Button {
                            startRecording()
                        } label: {
                            Text("开始录音")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                                .background(Capsule().fill(AppColors.warmOrange))
                        }
                    }
                }
                .padding(.bottom, 40)
            }
            .navigationTitle("录音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        stopRecording(save: false)
                        dismiss()
                    }
                }
            }
            .onDisappear { stopRecording(save: false) }
        }
    }

    private func startRecording() {
        let mediaStore = MediaStore.production()
        let filename = "voice-\(UUID().uuidString.prefix(8)).m4a"
        let dir = mediaStore.directoryURL(for: entryDraftID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            print("AVAudioSession 配置失败: \(error)")
            return
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.record()
            recordedURL = url
            isRecording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                elapsed += 0.1
            }
        } catch {
            print("录音失败: \(error)")
        }
    }

    private func stopRecording(save: Bool) {
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        recorder = nil

        guard save, let url = recordedURL else {
            isRecording = false
            return
        }

        let mediaStore = MediaStore.production()
        let relPath = "\(entryDraftID.uuidString)/\(url.lastPathComponent)"
        let draft = DraftAttachment(
            kind: .voice,
            relativePath: relPath,
            transcript: nil,
            durationSeconds: elapsed
        )
        let draftID = draft.id

        // 后台启动转写,不阻塞 UI
        Task.detached(priority: .utility) {
            let svc = TranscriptionService()
            let transcript = try? await svc.transcribe(audioURL: mediaStore.absoluteURL(relativePath: relPath))
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .voiceTranscribed,
                    object: nil,
                    userInfo: ["draftID": draftID, "transcript": transcript ?? ""]
                )
            }
        }

        onFinished(draft)
        dismiss()
    }
}

extension Notification.Name {
    static let voiceTranscribed = Notification.Name("voiceTranscribed")
}
