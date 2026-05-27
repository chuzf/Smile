import SwiftUI
import AVFoundation

struct VoicePlayerRow: View {
    let attachment: MediaAttachment

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var timer: Timer?
    @State private var showTranscript = true

    private let mediaStore = MediaStore.production()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(AppColors.warmOrange)
                }

                ProgressView(value: progress)
                    .tint(AppColors.warmOrange)

                Text(durationLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppColors.textSecondary)
            }

            if let transcript = attachment.transcript, !transcript.isEmpty {
                DisclosureGroup(isExpanded: $showTranscript) {
                    Text(transcript)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textPrimary.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    Text("转写")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textSecondary)
                }
            } else {
                Text("(转写处理中或不可用)")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textSecondary.opacity(0.6))
            }
        }
        .padding(12)
        .background(AppColors.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onDisappear { stopPlayback() }
    }

    private var durationLabel: String {
        let d = Int(attachment.durationSeconds ?? 0)
        return String(format: "%02d:%02d", d / 60, d % 60)
    }

    private func togglePlayback() {
        if isPlaying { stopPlayback() } else { startPlayback() }
    }

    private func startPlayback() {
        let url = mediaStore.absoluteURL(relativePath: attachment.relativePath)
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.play()
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                guard let p = player else { return }
                progress = p.duration > 0 ? p.currentTime / p.duration : 0
                if !p.isPlaying { stopPlayback() }
            }
        } catch { print("播放失败: \(error)") }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        isPlaying = false
        progress = 0
    }
}
