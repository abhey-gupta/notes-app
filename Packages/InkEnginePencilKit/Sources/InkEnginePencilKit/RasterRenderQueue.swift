import CoreGraphics
import InkModel
import Perf

/// Off-main page-image renders, a few at a time, nearest the viewport first (#70).
///
/// One waiting job per page (a newer request for the same page replaces the older one, so an edited page
/// never renders twice); ``maxConcurrent`` run at once on detached tasks; when one finishes the waiting
/// job with the lowest ``priority`` (distance from the viewport center) starts. Each render is a
/// `page.image.render` signpost. Results come back on the main actor in `completion`, superseded or not
/// (the caller caches them and checks whether they are still wanted).
@MainActor
final class RasterRenderQueue {
    /// Renders in flight at once. 2 keeps a scroll fed without starving the main thread; tests set 1.
    var maxConcurrent = 2
    /// Where a page is relative to the viewport (lower first); set by the engine on every viewport change.
    var priority: (PageID) -> Double = { _ in 0 }

    private struct Job {
        var key: PageLayerView.InkKey
        var render: RenderJob
        var pixelScale: CGFloat
        var completion: @MainActor (CGImage?) -> Void
    }

    private var waiting: [PageID: Job] = [:]
    private var running: Set<PageID> = []

    /// Jobs waiting or running.
    var depth: Int {
        waiting.count + running.count
    }

    var waitingCount: Int {
        waiting.count
    }

    /// Queues a render of `job` for `page` (replacing one waiting for the same page).
    func enqueue(
        _ page: PageID, key: PageLayerView.InkKey, job: RenderJob, pixelScale: CGFloat,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        waiting[page] = Job(key: key, render: job, pixelScale: pixelScale, completion: completion)
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
            let (render, scale) = (job.render, job.pixelScale)
            Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) {
                    Signpost.pageImageRender.measure { render.ink(scale: scale) }
                }.value
                guard let self else { return }
                running.remove(page)
                job.completion(image)
                pump()
            }
        }
    }
}
