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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tabs = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(OpenTabs.self, from: $0) } ?? OpenTabs()
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

    private func mutate<T>(_ change: (inout OpenTabs) -> T) -> T {
        let result = change(&tabs)
        if let data = try? JSONEncoder().encode(tabs) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        return result
    }
}
