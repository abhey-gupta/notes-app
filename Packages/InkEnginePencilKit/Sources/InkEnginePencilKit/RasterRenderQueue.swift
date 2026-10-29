import CoreGraphics
import InkModel
import Perf

/// Off-main page-image renders, a few at a time, nearest the viewport first (#70).
///
/// One waiting job per page (a newer request for the same page replaces the older one, so an edited page
/// never renders twice); ``maxConcurrent`` run at once on detached tasks; when one finishes the waiting
/// job with the lowest ``priority`` (distance from the viewport center) starts. Each render is a
/// `signpost` interval. Results come back on the main actor in `completion`, superseded or not (the
/// caller caches them and checks whether they are still wanted). The engine runs one queue for ink
/// rasters and others for imported artwork (`+Artwork`, #193).
@MainActor
final class RasterRenderQueue {
    /// Renders in flight at once. 2 keeps a scroll fed without starving the main thread; tests set 1.
    var maxConcurrent = 2
    /// Where a page is relative to the viewport (lower first); set by the engine on every viewport change.
    var priority: (PageID) -> Double = { _ in 0 }

    private struct Job {
        var render: @Sendable () -> CGImage?
        var completion: @MainActor (CGImage?) -> Void
    }

    private let signpost: Signpost
    private var waiting: [PageID: Job] = [:]
    private var running: Set<PageID> = []

    init(signpost: Signpost = .pageImageRender) {
        self.signpost = signpost
    }

    /// Jobs waiting or running.
    var depth: Int {
        waiting.count + running.count
    }

    var waitingCount: Int {
        waiting.count
    }

    /// Queues `render` for `page` (replacing one waiting for the same page).
    func enqueue(
        _ page: PageID, render: @escaping @Sendable () -> CGImage?,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        waiting[page] = Job(render: render, completion: completion)
        pump()
    }

    /// Drops the waiting job of `page` (a running one finishes on its own).
    func cancel(_ page: PageID) {
        waiting[page] = nil
    }

    /// Drops every waiting job of a page `unwanted` accepts (pages that left the viewport).
    func dropWaiting(where unwanted: (PageID) -> Bool) {
        for page in waiting.keys where unwanted(page) {
            waiting[page] = nil
        }
    }

    private func pump() {
        while running.count < maxConcurrent, let next = waiting.min(by: { priority($0.key) < priority($1.key) }) {
            let (page, job) = next
            waiting[page] = nil
            running.insert(page)
            let (render, signpost) = (job.render, signpost)
            Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) {
                    signpost.measure { render() }
                }.value
                guard let self else { return }
                running.remove(page)
                job.completion(image)
                pump()
            }
        }
    }
}
