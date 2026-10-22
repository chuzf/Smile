import SwiftUI
import SwiftData
import AVFoundation
import Speech

struct VoiceRecorderView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) private var context
    let entryDraftID: UUID
    let onFinished: (DraftAttachment) -> Void

    @State private var recorder: AVAudioRecorder?
    @State private var isRecording = false
    @State private var pulse = false
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var recordedURL: URL?
    @State private var isRequestingPermission = false
    @State private var showMicDeniedAlert = false
    @State private var showRecordFailedAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 88))
                    .foregroundStyle(isRecording ? Color.red : AppColors.warmOrange)
                if isRecording {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                            .opacity(pulse ? 1 : 0.3)
                            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                        Text("正在录音")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    .onAppear { pulse = true }
                }
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
                            Task { await requestPermissionAndRecord() }
                        } label: {
                            Text("开始录音")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                                .background(Capsule().fill(AppColors.warmOrange))
                        }
                        .disabled(isRequestingPermission)
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
            .alert("需要麦克风权限", isPresented: $showMicDeniedAlert) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("去设置") { UIApplication.shared.open(url) }
                }
                Button("好的", role: .cancel) { }
            } message: {
                Text("请前往「设置」>「隐私与安全性」>「麦克风」开启后再录音")
            }
            .alert("无法录音", isPresented: $showRecordFailedAlert) {
                Button("好的", role: .cancel) { }
            } message: {
                Text("录音启动失败，请稍后再试。")
            }
        }
        // 录音中下滑关闭会直接丢掉录音：必须点「完成」或「取消」
        .interactiveDismissDisabled(isRecording)
    }

    /// 先确认麦克风权限：未授权时 AVAudioRecorder 只会录下静音，不能让用户白录
    private func requestPermissionAndRecord() async {
        guard !isRequestingPermission, !isRecording else { return }
        isRequestingPermission = true
        let granted = await AVAudioApplication.requestRecordPermission()
        isRequestingPermission = false
        guard granted else {
            showMicDeniedAlert = true
            return
        }
        startRecording()
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
            showRecordFailedAlert = true
            return
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            // record() 返回 false 表示没能开始录音（如音频会话被占用），不能进入录音状态
            guard newRecorder.record() else {
                newRecorder.deleteRecording()
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                showRecordFailedAlert = true
                return
            }
            recorder = newRecorder
            recordedURL = url
            isRecording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                elapsed += 0.1
            }
        } catch {
            print("录音失败: \(error)")
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            showRecordFailedAlert = true
        }
    }

    private func stopRecording(save: Bool) {
        let wasRecording = recorder != nil
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        recorder = nil
        if wasRecording {
            // 交还音频会话，让被打断的其它 App 音频恢复播放
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        guard save, let url = recordedURL else {
            // 取消 / 关闭：录下的文件不会交给编辑器，没人引用，直接删掉
            if let url = recordedURL {
                try? FileManager.default.removeItem(at: url)
            }
            recordedURL = nil
            isRecording = false
            return
        }
        // 交给编辑器后不再归本视图管：之后的 onDisappear（save: false）不能删它
        recordedURL = nil

        let mediaStore = MediaStore.production()
        let relPath = "\(entryDraftID.uuidString)/\(url.lastPathComponent)"
        let draft = DraftAttachment(
            kind: .voice,
            relativePath: relPath,
            transcript: nil,
            durationSeconds: elapsed
        )
        let draftID = draft.id
        let container = context.container

        // 后台启动转写,不阻塞 UI
        Task.detached(priority: .utility) {
            // 从未询问过语音识别权限时先请求，否则 transcribe 直接因未授权失败、永远没有转写
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                guard await TranscriptionService.requestAuthorization() else { return }
            }
            let svc = TranscriptionService()
            // 失败或没识别出文字时保持 nil，不写空串
            guard let transcript = try? await svc.transcribe(audioURL: mediaStore.absoluteURL(relativePath: relPath)),
                  !transcript.isEmpty else { return }
            await MainActor.run {
                // 编辑器还开着：更新草稿，随保存一起写入
                NotificationCenter.default.post(
                    name: .voiceTranscribed,
                    object: nil,
                    userInfo: ["draftID": draftID, "transcript": transcript]
                )
                // 编辑器可能已保存并关闭，没人接收通知：直接补写到已保存的附件上
                Self.persistTranscript(transcript, relativePath: relPath, in: container.mainContext)
            }
        }

        onFinished(draft)
        dismiss()
    }

    @MainActor
    static func persistTranscript(_ transcript: String, relativePath: String, in context: ModelContext) {
        let descriptor = FetchDescriptor<MediaAttachment>(
            predicate: #Predicate { $0.relativePath == relativePath }
        )
        guard let attachments = try? context.fetch(descriptor) else { return }
        var changed = false
        for att in attachments where att.transcript?.isEmpty ?? true {
            att.transcript = transcript
            changed = true
        }
        if changed { try? context.save() }
    }
}

extension Notification.Name {
    static let voiceTranscribed = Notification.Name("voiceTranscribed")
}
