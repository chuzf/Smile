import UIKit

enum ThumbnailGenerator {

    /// 给定原图 Data,返回长边 400px 的 JPEG 缩略图 Data
    static func makePhotoThumbnail(from data: Data, maxSide: CGFloat = 400) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(maxSide / max(image.size.width, image.size.height), 1)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let thumb = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return thumb.jpegData(compressionQuality: 0.8)
    }

}
