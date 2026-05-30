import Testing
import Foundation
import SwiftData
@testable import Smile

@Suite("SearchService", .serialized)
@MainActor
struct SearchServiceTests {

    @Test func matchesTitle() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let g = Group(name: "微笑", iconSymbol: "x", colorHex: "#000")
        ctx.insert(g)
        let e1 = Entry(title: "咖啡店", bodyText: "", group: g)
        let e2 = Entry(title: "妈妈电话", bodyText: "", group: g)
        ctx.insert(e1); ctx.insert(e2)
        try ctx.save()

        let results = try SearchService.search(in: ctx, query: "咖啡", group: nil)
        #expect(results.contains { $0.id == e1.id })
        #expect(!results.contains { $0.id == e2.id })
    }

    @Test func matchesBody() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let g = Group(name: "微笑", iconSymbol: "x", colorHex: "#000")
        ctx.insert(g)
        let e = Entry(title: "x", bodyText: "今天去了南京西路", group: g)
        ctx.insert(e); try ctx.save()

        let r = try SearchService.search(in: ctx, query: "南京西路", group: nil)
        #expect(r.count == 1)
    }

    @Test func scopeByGroup() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let g1 = Group(name: "A", iconSymbol: "x", colorHex: "#000")
        let g2 = Group(name: "B", iconSymbol: "x", colorHex: "#000")
        ctx.insert(g1); ctx.insert(g2)
        ctx.insert(Entry(title: "match", bodyText: "", group: g1))
        ctx.insert(Entry(title: "match", bodyText: "", group: g2))
        try ctx.save()

        let r = try SearchService.search(in: ctx, query: "match", group: g1)
        #expect(r.count == 1)
        #expect(r.first?.group?.name == "A")
    }
}
