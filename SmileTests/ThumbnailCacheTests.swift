import XCTest
import UIKit
@testable import Smile

final class ThumbnailCacheTests: XCTestCase {

    func testSetAndGet() {
        let cache = ThumbnailCache()
        let img = makeImage()
        cache.set(img, forKey: "key1")
        XCTAssertNotNil(cache.get("key1"))
    }

    func testMissReturnsNil() {
        let cache = ThumbnailCache()
        XCTAssertNil(cache.get("nonexistent"))
    }

    func testDifferentKeysAreIndependent() {
        let cache = ThumbnailCache()
        let img = makeImage()
        cache.set(img, forKey: "a")
        XCTAssertNotNil(cache.get("a"))
        XCTAssertNil(cache.get("b"))
    }

    func testOverwriteUpdatesValue() {
        let cache = ThumbnailCache()
        let img1 = makeImage(color: .red)
        let img2 = makeImage(color: .blue)
        cache.set(img1, forKey: "k")
        cache.set(img2, forKey: "k")
        XCTAssertIdentical(cache.get("k"), img2)
    }

    private func makeImage(color: UIColor = .gray) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }
}
