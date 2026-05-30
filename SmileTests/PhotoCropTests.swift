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
        // Simulate a camera photo with .right orientation.
        // Use scale:1 format so cgImage pixels == points (no 3x screen scaling).
        let cgSize = CGSize(width: 300, height: 200) // raw cgImage is landscape (300 wide, 200 tall)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let cgImg = UIGraphicsImageRenderer(size: cgSize, format: fmt)
            .image { ctx in UIColor.blue.setFill(); ctx.fill(CGRect(origin: .zero, size: cgSize)) }
            .cgImage!
        // Wrap with .right orientation → UIKit treats it as portrait: size = (200, 300)
        let source = UIImage(cgImage: cgImg, scale: 1.0, orientation: .right)
        // source.size == (200, 300) in points
        XCTAssertEqual(source.size.width,  200, accuracy: 1, "pre-check: source width")
        XCTAssertEqual(source.size.height, 300, accuracy: 1, "pre-check: source height")

        // imageRect matches source.size (200×300), cropRect selects a 100×100 region
        let imageRect = CGRect(x: 0, y: 0, width: 200, height: 300)
        let cropRect  = CGRect(x: 50, y: 100, width: 100, height: 100)
        let result = PhotoCropView.cropImage(source, cropRect: cropRect, imageRect: imageRect)
        // Expected: 100×100 pt result, not the original 200×300
        XCTAssertEqual(result.size.width,  100, accuracy: 2, "Width should match crop, not original")
        XCTAssertEqual(result.size.height, 100, accuracy: 2, "Height should match crop, not original")
        XCTAssertFalse(result.size == source.size, "Should not return source unchanged")
    }

    private func makeImage(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
