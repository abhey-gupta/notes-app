import Foundation
import InkModel
@testable import Library
import Testing

struct OpenTabsTests {
    private let a = NotebookID(), b = NotebookID(), c = NotebookID()

    @Test func openAppendsAndActivates() {
        var tabs = OpenTabs()
        #expect(tabs.isEmpty)
        tabs.open(a)
        tabs.open(b)
        #expect(tabs.ids == [a, b])
        #expect(tabs.active == b)
        tabs.open(a)
        #expect(tabs.ids == [a, b], "reopening doesn't duplicate or reorder")
        #expect(tabs.active == a)
    }

    @Test func closingActiveShowsRightNeighbourThenLeft() {
        var tabs = OpenTabs()
        tabs.open(a)
        tabs.open(b)
        tabs.open(c)
        tabs.activate(b)
        tabs.close(b)
        #expect(tabs.ids == [a, c])
        #expect(tabs.active == c, "right-hand neighbour")
        tabs.close(c)
        #expect(tabs.active == a, "left one at the end")
        tabs.close(a)
        #expect(tabs.isEmpty)
        #expect(tabs.active == nil)
    }

    @Test func closingInactiveKeepsActive() {
        var tabs = OpenTabs()
        tabs.open(a)
        tabs.open(b)
        tabs.close(a)
        #expect(tabs.active == b)
        #expect(tabs.ids == [b])
    }

    @Test func closeOthers() {
        var tabs = OpenTabs()
        tabs.open(a)
        tabs.open(b)
        tabs.open(c)
        tabs.closeOthers(keeping: a)
        #expect(tabs.ids == [a])
        #expect(tabs.active == a)
    }

    @Test func limitEvictsLeastRecentlyActive() {
        var tabs = OpenTabs()
        let ids = (0 ..< OpenTabs.limit).map { _ in NotebookID() }
        for id in ids {
            tabs.open(id)
        }
        tabs.activate(ids[0])
        let extra = NotebookID()
        let evicted = tabs.open(extra)
        #expect(evicted == ids[1], "ids[0] was just used; ids[1] is the coldest")
        #expect(tabs.count == OpenTabs.limit)
        #expect(tabs.active == extra)
        #expect(!tabs.contains(ids[1]))
    }

    @Test func pruneDropsMissing() {
        var tabs = OpenTabs()
        tabs.open(a)
        tabs.open(b)
        tabs.open(c)
        #expect(tabs.prune(keeping: [a, b]) == [c])
        #expect(tabs.ids == [a, b])
        #expect(tabs.active == b)
    }

    @Test func nextAndPreviousWrap() {
        var tabs = OpenTabs()
        #expect(tabs.next == nil)
        tabs.open(a)
        #expect(tabs.next == nil, "a lone tab has no neighbour")
        tabs.open(b)
        tabs.open(c)
        #expect(tabs.next == a)
        #expect(tabs.previous == b)
    }

    @Test func roundTrips() throws {
        var tabs = OpenTabs()
        tabs.open(a)
        tabs.open(b)
        tabs.activate(a)
        let decoded = try JSONDecoder().decode(OpenTabs.self, from: JSONEncoder().encode(tabs))
        #expect(decoded == tabs)
        var copy = decoded
        copy.open(c)
        #expect(copy.ids == [a, b, c])
    }
}
