import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import Testing

@Suite(.timeLimit(.minutes(2)))
@MainActor
struct RasterRenderQueueTests {
    private func job(_ page: UInt8) -> (PageID, RenderJob) {
        let id = RenderFixtures.pageID(page)
        let stroke = RenderFixtures.line(page, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 10))
        let snapshot = PageSnapshot(page: Page(id: id, template: .blank, strokes: [stroke], rev: 1), size: CGSize(width: 100, height: 100))
        return (id, RenderJob(page: snapshot, palette: FixturePalette(), theme: .white))
    }

    /// With one render at a time, the queued pages start nearest the viewport first, and the depth gauge
    /// counts what waits and runs.
    @Test func nearestTheViewportRendersFirst() async throws {
        let queue = RasterRenderQueue()
        queue.maxConcurrent = 1
        let distance: [PageID: Double] = [RenderFixtures.pageID(1): 0, RenderFixtures.pageID(2): 900, RenderFixtures.pageID(3): 400]
        queue.priority = { distance[$0] ?? .infinity }
        var done: [PageID] = []
        for n: UInt8 in [1, 2, 3] {
            let (id, render) = job(n)
            queue.enqueue(id, render: { render.ink(scale: 1) }, completion: { image in
                #expect(image != nil)
                done.append(id)
            })
        }
        #expect(queue.depth == 3 && queue.waitingCount == 2, "one running, two waiting")
        for _ in 0 ..< 500 where done.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(done == [RenderFixtures.pageID(1), RenderFixtures.pageID(3), RenderFixtures.pageID(2)])
        #expect(queue.depth == 0)
    }

    /// A newer request for a page replaces the one waiting; a cancelled page never renders.
    @Test func laterRequestReplacesTheWaitingOne() async throws {
        let queue = RasterRenderQueue()
        queue.maxConcurrent = 1
        var completed: [CGFloat] = []
        let (first, firstJob) = job(1)
        queue.enqueue(first, render: { firstJob.ink(scale: 1) }, completion: { _ in completed.append(1) })
        let (second, secondJob) = job(2)
        queue.enqueue(second, render: { secondJob.ink(scale: 1) }, completion: { _ in completed.append(2) })
        queue.enqueue(second, render: { secondJob.ink(scale: 2) }, completion: { _ in completed.append(2.5) })
        let (third, thirdJob) = job(3)
        queue.enqueue(third, render: { thirdJob.ink(scale: 1) }, completion: { _ in completed.append(3) })
        queue.cancel(third)
        #expect(queue.waitingCount == 1)
        for _ in 0 ..< 500 where queue.depth > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed == [1, 2.5])
    }
}
