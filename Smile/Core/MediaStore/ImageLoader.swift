import UIKit
import ImageIO

/// 用 ImageIO 只解码到目标尺寸，并按 EXIF 方向摆正；避免把整张原图解码进内存
enum ImageLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 100 * 1024 * 1024
        return cache
    }()

    /// 长边不超过 maxPixel；原图更小时保持原尺寸。文件不存在或无法解码时返回 nil
    static func downsampled(url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// 带内存缓存的 downsampled。照片文件名带 UUID、写入后不再改写，按路径缓存是安全的
    static func cachedDownsampled(url: URL, maxPixel: Int) -> UIImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = downsampled(url: url, maxPixel: maxPixel) else { return nil }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// 只读文件头：按 EXIF 方向摆正后的像素尺寸，用来给占位图算宽高比
    static func orientedPixelSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        // EXIF 方向 5–8 需要旋转 90°，宽高互换
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
