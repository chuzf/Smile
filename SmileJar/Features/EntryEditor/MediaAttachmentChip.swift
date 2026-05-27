import SwiftUI

struct MediaAttachmentChip: View {
    let draft: DraftAttachment
    let thumbnail: UIImage?
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .font(.system(size: 18))
            }
            .offset(x: 6, y: -6)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.2)
            Image(systemName: iconForKind)
                .font(.system(size: 22))
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    private var iconForKind: String {
        switch draft.kind {
        case .photo: return "photo"
        case .video: return "video"
        case .voice: return "waveform"
        }
    }
}
