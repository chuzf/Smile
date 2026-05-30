import SwiftUI
import UIKit

@MainActor
enum ShareCardRenderer {

    struct CardData {
        let groupName: String
        let dateText: String
        let title: String
        let bodySnippet: String
        let primaryImage: UIImage?
    }

    /// 输出 1080×1920 PNG
    static func render(_ data: CardData) -> UIImage? {
        let view = ShareCardView(data: data)
            .frame(width: 1080, height: 1920)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage
    }
}

private struct ShareCardView: View {
    let data: ShareCardRenderer.CardData

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 1, green: 0.96, blue: 0.89),
                         Color(red: 1, green: 0.91, blue: 0.82)],
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 40) {
                Text("\(data.groupName) · \(data.dateText)")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Color(red: 0.78, green: 0.48, blue: 0.23))

                if let image = data.primaryImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 800)
                        .clipShape(RoundedRectangle(cornerRadius: 32))
                } else {
                    RoundedRectangle(cornerRadius: 32)
                        .fill(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: 600)
                }

                Text(data.title)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(Color(red: 0.35, green: 0.23, blue: 0.12))

                Text(data.bodySnippet)
                    .font(.system(size: 32))
                    .foregroundStyle(Color(red: 0.4, green: 0.3, blue: 0.2))
                    .lineLimit(4)

                Spacer()
                HStack {
                    Spacer()
                    Text("存于 \(data.groupName) 🍯")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Color(red: 0.6, green: 0.45, blue: 0.3))
                }
            }
            .padding(80)
        }
    }
}
