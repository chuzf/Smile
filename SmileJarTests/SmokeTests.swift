import Testing

@Suite("Smoke")
struct SmokeTests {
    @Test func arithmetic() {
        #expect(1 + 1 == 2)
    }
}
