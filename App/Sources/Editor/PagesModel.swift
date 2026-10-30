import Canvas
import DesignSystem
import Foundation
import InkModel
import Observation
import os
import Perf

/// Pages overview state (mock §04, #32): the page list the grid shows and the actions it asks the
/// session to perform. The session keeps ``entries`` current after every structure change (its own,
/// undo, redo) and bumps a page's thumbnail version when `thumbs/<id>.heic` is rewritten.
@MainActor
@Observable
final class PagesModel {
    /// One grid cell: identity, template and where its thumbnail lives (missing file = placeholder).
    struct Entry: Identifiable, Hashable {
        let id: PageID
        var pattern: PaperPattern
        var thumbnail: URL?
    }

    /// Opening and closing fly the page between the canvas and its cell (#124, `PageFlightView`); the
    /// overlay is on screen for every phase but `.closed`, the chrome for `.closed` and `.closing`.
    enum Phase: Equatable {
        case closed, opening, open, closing
    }

    private(set) var phase: Phase = .closed
    var isPresented: Bool {
        phase != .closed
    }

    private(set) var entries: [Entry] = []
    /// Cache key per page: changes when the page's thumbnail file was rewritten while the overview is up.
    private(set) var thumbnailVersions: [PageID: Date] = [:]
    /// Pages tap → the overlay's first frame, for the < 100 ms budget (`page.overview` signpost).
    private(set) var openMilliseconds: Double?

    /// Put the page (0-based) on screen, under the overlay; the overlay then flies it up and dismisses.
    @ObservationIgnored var onShow: (Int) -> Void = { _ in }
    /// The page (0-based) as drawn right now, frames in window coordinates; `true` waits for a pending
    /// layout (after ``onShow``). `nil`: no flight, crossfade instead.
    @ObservationIgnored var capturePage: (Int, _ afterScreenUpdates: Bool) -> PageCapture? = { _, _ in nil }
    /// Insert a page with the template after the index (`nil` appends).
    @ObservationIgnored var onInsert: (Int?, PaperStyle) -> Void = { _, _ in }
    @ObservationIgnored var onMove: (_ from: Int, _ to: Int) -> Void = { _, _ in }
    @ObservationIgnored var onDelete: ([PageID]) -> Void = { _ in }
    /// Whether any of the pages has strokes (delete confirms only then).
    @ObservationIgnored var hasInk: ([PageID]) async -> Bool = { _ in false }
    /// A cell came on screen / left it: its page gets a thumbnail if it has none (#207).
    @ObservationIgnored var onCellAppear: (PageID) -> Void = { _ in }
    @ObservationIgnored var onCellDisappear: (PageID) -> Void = { _ in }

    @ObservationIgnored private var opening: (interval: SignpostInterval, start: ContinuousClock.Instant)?
    @ObservationIgnored private var openedAt = Date()
    private static let log = Logger(subsystem: Signpost.subsystem, category: "page")

    func present() {
        guard phase == .closed else { return }
        openMilliseconds = nil
        openedAt = Date()
        thumbnailVersions = [:]
        opening = (Signpost.pagesOverview.begin(), .now)
        phase = .opening
    }

    /// The page landed in its cell (or crossfaded): the overview takes input.
    func didOpen() {
        guard phase == .opening else { return }
        phase = .open
    }

    /// The flight back started: the chrome fades in under the overlay.
    func willDismiss() {
        guard phase == .open else { return }
        phase = .closing
    }

    /// The overlay drew its first frame.
    func didRenderFirstFrame() {
        guard let opening else { return }
        opening.interval.end()
        self.opening = nil
        let elapsed = (ContinuousClock.now - opening.start).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        openMilliseconds = ms
        let count = entries.count
        Self.log.notice("pages.overview firstFrame \(ms, format: .fixed(precision: 1), privacy: .public) ms, \(count) pages")
    }

    /// The overlay leaves (the page is back on the canvas).
    func dismiss() {
        opening?.interval.end()
        opening = nil
        phase = .closed
    }

    func setEntries(_ entries: [Entry]) {
        if self.entries != entries {
            self.entries = entries
        }
    }

    /// Version for the cell's thumbnail cache key.
    func thumbnailVersion(_ id: PageID) -> Date {
        thumbnailVersions[id] ?? openedAt
    }

    /// `thumbs/<id>.heic` was rewritten: the cell reloads it.
    func thumbnailWritten(_ id: PageID) {
        guard isPresented else { return }
        thumbnailVersions[id] = Date()
    }
}

extension PageTemplate {
    /// The template's look for SwiftUI placeholders.
    var pattern: PaperPattern {
        switch self {
        case .blank: .blank
        case .lined: .lined
        case .dotted: .dotted
        case .grid: .grid
        case .cornell: .cornell
        }
    }
}
