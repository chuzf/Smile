import Testing
import Foundation
@testable import Smile

@Suite("KeychainService", .serialized)
struct KeychainServiceTests {
    let service = KeychainService(service: "com.smilejar.test")

    @Test func setAndGet() throws {
        try service.set("test_key", value: "secret_value")
        #expect(service.get("test_key") == "secret_value")
        try service.delete("test_key")
    }

    @Test func deleteRemoves() throws {
        try service.set("k", value: "v")
        try service.delete("k")
        #expect(service.get("k") == nil)
    }

    @Test func getMissingReturnsNil() throws {
        #expect(service.get("never_set") == nil)
        // 不存在不算错误，read 返回 nil 而不是抛出
        #expect(try service.read("never_set") == nil)
    }

    @Test func readReturnsStoredValue() throws {
        try service.set("r", value: "v")
        #expect(try service.read("r") == "v")
        try service.delete("r")
    }

    @Test func overwriteSamekey() throws {
        try service.set("k", value: "v1")
        try service.set("k", value: "v2")
        #expect(service.get("k") == "v2")
        try service.delete("k")
    }
}
