import Testing
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Smile

@Suite("ImageLoader")
struct ImageLoaderTests {
    /// 写一张纯色 JPEG 到临时目录；orientation 为 EXIF 方向值（1 = 正常）
    private func writeJPEG(width: Int, height: Int, orientation: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("imageloader-\(UUID().uuidString).jpg")
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        ctx.setFillColor(UIColor.orange.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    private func pixelSize(_ image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    @Test func downsamplesLongSide() throws {
        let url = try writeJPEG(width: 3000, height: 2000)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(ImageLoader.downsampled(url: url, maxPixel: 1000))
        let size = pixelSize(image)
        #expect(size.width == 1000)
        #expect(abs(size.height - 667) <= 1)
    }

    @Test func doesNotUpscale() throws {
        let url = try writeJPEG(width: 3000, height: 2000)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(ImageLoader.downsampled(url: url, maxPixel: 10000))
        #expect(pixelSize(image) == CGSize(width: 3000, height: 2000))
    }

    @Test func appliesEXIFOrientation() throws {
        let url = try writeJPEG(width: 3000, height: 2000, orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(ImageLoader.downsampled(url: url, maxPixel: 4096))
        #expect(pixelSize(image) == CGSize(width: 2000, height: 3000))
        #expect(ImageLoader.orientedPixelSize(url: url) == CGSize(width: 2000, height: 3000))
    }

    @Test func orientedPixelSizeOfUprightImage() throws {
        let url = try writeJPEG(width: 3000, height: 2000)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ImageLoader.orientedPixelSize(url: url) == CGSize(width: 3000, height: 2000))
    }

    @Test func missingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).jpg")
        #expect(ImageLoader.downsampled(url: url, maxPixel: 1000) == nil)
        #expect(ImageLoader.cachedDownsampled(url: url, maxPixel: 1000) == nil)
        #expect(ImageLoader.orientedPixelSize(url: url) == nil)
    }

    @Test func cachedReturnsSameInstance() throws {
        let url = try writeJPEG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try #require(ImageLoader.cachedDownsampled(url: url, maxPixel: 400))
        let second = try #require(ImageLoader.cachedDownsampled(url: url, maxPixel: 400))
        #expect(first === second)
    }
}
