import SwiftUI

struct PhotoCarousel: View {
    let photoPaths: [String]   // 相对路径

    private let mediaStore = MediaStore.production()

    var body: some View {
        if photoPaths.isEmpty {
            EmptyView()
        } else {
            TabView {
                ForEach(photoPaths, id: \.self) { path in
                    if let img = loadImage(path) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
            }
            .tabViewStyle(.page)
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func loadImage(_ path: String) -> UIImage? {
        guard let data = try? mediaStore.loadData(relativePath: path) else { return nil }
        return UIImage(data: data)
    }
}
