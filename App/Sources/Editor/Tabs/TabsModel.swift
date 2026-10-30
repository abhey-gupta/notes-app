import Foundation
import InkModel
import Library
import Observation

/// The notebooks open as editor tabs (#191), saved to `UserDefaults` on every change so the editor comes
/// back with the same tabs after a relaunch. Logic lives in ``OpenTabs``; this adds observation and persistence.
@MainActor
@Observable
final class TabsModel {
    static let defaultsKey = "openTabs"

    private(set) var tabs: OpenTabs
    @ObservationIgnored private let defaults: UserDefaults

    /// The window whose tabs are saved (#175): the one used last. Another window's tabs live as long as it does.
    private weak static var writer: TabsModel?

    /// - Parameter restores: Starts with the saved tabs (the first window); a further window starts empty.
    init(defaults: UserDefaults = .standard, restores: Bool = true) {
        self.defaults = defaults
        let saved = restores ? defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(OpenTabs.self, from: $0) } : nil
        tabs = saved ?? OpenTabs()
        if restores, Self.writer == nil {
            Self.writer = self
        }
    }

    /// This window came forward: its tabs are the ones saved from now on.
    func becomeWriter() {
        guard Self.writer !== self else { return }
        Self.writer = self
        save()
    }

    /// Tabs in bar order.
    var ids: [NotebookID] {
        tabs.ids
    }

    /// The tab showing.
    var active: NotebookID? {
        tabs.active
    }

    var openIDs: Set<NotebookID> {
        Set(tabs.ids)
    }

    /// Shows `id` (a new tab or the existing one); returns the tab evicted to stay under the limit, if any.
    @discardableResult
    func open(_ id: NotebookID) -> NotebookID? {
        mutate { $0.open(id) }
    }

    func activate(_ id: NotebookID) {
        mutate { $0.activate(id) }
    }

    func activateNext() {
        if let next = tabs.next {
            activate(next)
        }
    }

    func activatePrevious() {
        if let previous = tabs.previous {
            activate(previous)
        }
    }

    func close(_ id: NotebookID) {
        mutate { $0.close(id) }
    }

    // MARK: Split view (#175)

    var secondary: NotebookID? {
        tabs.secondary
    }

    var isSplit: Bool {
        tabs.isSplit
    }

    var focus: OpenTabs.Pane {
        tabs.focus
    }

    var splitFraction: Double {
        get { tabs.splitFraction }
        set { mutate { $0.splitFraction = newValue } }
    }

    func showing(_ pane: OpenTabs.Pane) -> NotebookID? {
        tabs.showing(pane)
    }

    /// Opens `id` beside the showing tab; returns the tab evicted to stay under the limit, if any.
    @discardableResult
    func openSplit(_ id: NotebookID) -> NotebookID? {
        mutate { $0.openSplit(id) }
    }

    func show(_ id: NotebookID, in pane: OpenTabs.Pane) {
        mutate { $0.show(id, in: pane) }
    }

    func closeSplit(keeping pane: OpenTabs.Pane) {
        mutate { $0.closeSplit(keeping: pane) }
    }

    func swapPanes() {
        mutate { $0.swapPanes() }
    }

    /// `pane` was touched (written in, scrolled, its bar tapped). Cheap when it already has focus.
    func focus(_ pane: OpenTabs.Pane) {
        guard tabs.focus != pane else { return }
        mutate { $0.focus(pane) }
    }

    func closeOthers(keeping id: NotebookID) {
        mutate { $0.closeOthers(keeping: id) }
    }

    /// Drops tabs whose notebooks are gone (deleted from the library). Returns them.
    @discardableResult
    func prune(keeping existing: Set<NotebookID>) -> [NotebookID] {
        mutate { $0.prune(keeping: existing) }
    }

    /// Forgets the saved tabs (UI tests, `-resetToolState`).
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    private func save() {
        guard Self.writer === self, let data = try? JSONEncoder().encode(tabs) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func mutate<T>(_ change: (inout OpenTabs) -> T) -> T {
        let result = change(&tabs)
        save()
        return result
    }
}
