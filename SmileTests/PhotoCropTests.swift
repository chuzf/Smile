import XCTest
@testable import Smile

final class PhotoCropTests: XCTestCase {

    func testCropFullImage() {
        let size = CGSize(width: 200, height: 200)
        let img = makeImage(size: size)
        let imageRect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let cropRect  = CGRect(x: 0, y: 0, width: 200, height: 200)
        let result = PhotoCropView.cropImage(img, cropRect: cropRect, imageRect: imageRect)
        XCTAssertEqual(result.size.width,  200, accuracy: 1)
        XCTAssertEqual(result.size.height, 200, accuracy: 1)
    }

    func testCropTopLeft() {
        let size = CGSize(width: 200, height: 200)
        let img = makeImage(size: size)
        let imageRect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let cropRect  = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = PhotoCropView.cropImage(img, cropRect: cropRect, imageRect: imageRect)
        XCTAssertEqual(result.size.width,  100, accuracy: 1)
        XCTAssertEqual(result.size.height, 100, accuracy: 1)
    }

    func testCropCenter() {
        let img = makeImage(size: CGSize(width: 400, height: 400))
        let imageRect = CGRect(x: 50, y: 50, width: 300, height: 300)
        let cropRect  = CGRect(x: 125, y: 125, width: 150, height: 150)
        let result = PhotoCropView.cropImage(img, cropRect: cropRect, imageRect: imageRect)
        // 150/300 * 400 = 200
        XCTAssertEqual(result.size.width,  200, accuracy: 2)
        XCTAssertEqual(result.size.height, 200, accuracy: 2)
    }

    func testCropClampsToImageBounds() {
        let img = makeImage(size: CGSize(width: 100, height: 100))
        let imageRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cropRect  = CGRect(x: -10, y: -10, width: 200, height: 200)
        let result = PhotoCropView.cropImage(img, cropRect: cropRect, imageRect: imageRect)
        XCTAssertEqual(result.size.width,  100, accuracy: 1)
        XCTAssertEqual(result.size.height, 100, accuracy: 1)
    }

    func testCropRightOrientationImage() {
        // Create a 300×200 two-tone cgImage: left half red, right half blue (at scale 1)
        let cgSize = CGSize(width: 300, height: 200)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let raw = UIGraphicsImageRenderer(size: cgSize, format: fmt).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 150, height: 200))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 150, y: 0, width: 150, height: 200))
        }
        let cgImg = raw.cgImage!
        // Wrap with .right orientation: UIKit treats as 200×300 portrait
        let source = UIImage(cgImage: cgImg, scale: 1.0, orientation: .right)
        XCTAssertEqual(source.size, CGSize(width: 200, height: 300))

        // imageRect == source.size (no pan/zoom), crop the top 100pt strip
        let imageRect = CGRect(origin: .zero, size: source.size) // 200×300
        let cropRect  = CGRect(x: 0, y: 0, width: 200, height: 100) // top strip
        let result = PhotoCropView.cropImage(source, cropRect: cropRect, imageRect: imageRect)

        // Output size must match cropRect
        XCTAssertEqual(result.size.width,  200, accuracy: 2)
        XCTAssertEqual(result.size.height, 100, accuracy: 2)
        XCTAssertFalse(result.size == source.size, "Must not return source unchanged")

        // Verify the crop has actual content (not degenerate/empty)
        XCTAssertNotNil(result.cgImage)
    }

    private func makeImage(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
