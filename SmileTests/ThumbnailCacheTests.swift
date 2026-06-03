import XCTest
import UIKit
@testable import Smile

final class ThumbnailCacheTests: XCTestCase {

    // Each test uses a unique key prefix to avoid cross-test state pollution
    // when using the shared ThumbnailCache instance (ThumbnailCache is private
    // to its file and not directly constructible outside that file scope).
    private var prefix: String = ""

    override func setUp() {
        super.setUp()
        prefix = UUID().uuidString + "_"
    }

    func testSetAndGet() {
        let img = makeImage()
        ThumbnailCache.shared.set(img, forKey: prefix + "key1")
        XCTAssertNotNil(ThumbnailCache.shared.get(prefix + "key1"))
    }

    func testMissReturnsNil() {
        XCTAssertNil(ThumbnailCache.shared.get(prefix + "nonexistent"))
    }

    func testDifferentKeysAreIndependent() {
        let img = makeImage()
        ThumbnailCache.shared.set(img, forKey: prefix + "a")
        XCTAssertNotNil(ThumbnailCache.shared.get(prefix + "a"))
        XCTAssertNil(ThumbnailCache.shared.get(prefix + "b"))
    }

    func testOverwriteUpdatesValue() {
        let img1 = makeImage(color: .red)
        let img2 = makeImage(color: .blue)
        ThumbnailCache.shared.set(img1, forKey: prefix + "k")
        ThumbnailCache.shared.set(img2, forKey: prefix + "k")
        XCTAssertIdentical(ThumbnailCache.shared.get(prefix + "k"), img2)
    }

    private func makeImage(color: UIColor = .gray) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }
}
