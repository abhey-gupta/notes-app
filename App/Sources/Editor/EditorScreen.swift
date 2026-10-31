import Canvas
import DesignSystem
import InkModel
import Library
import SwiftUI
import Tools

/// Full-screen editor (§7): the desk, one notebook pane (``EditorPane``: canvas + its bar, #21/#31/#191),
/// or two in split view (#175), and the floating tools capsule they share.
///
/// Tabs (#191): each pane's bar lists every open notebook (``TabsModel``); switching swaps the pane's
/// canvas for that tab's session (``SessionStore``), which stays open behind the others. Leaving for the
/// library closes every session (tabs stay); coming back reopens the showing ones.
///
/// Split view (#175): Open in Split View (a tab's context menu, the pane's ⋯, the library) brings a
/// second pane in beside the first: side by side when the editor is wider than tall, stacked otherwise
/// (``SplitGeometry``). One spring moves everything: the new pane slides in from its edge at its final
/// size while the other pane narrows, its page shrinking in place (`CanvasHostView.beginLiveResize`: a
/// snapshot follows the frame, the canvas refits once at the end), and the divider fades in last. The
/// divider drags live between ⅓ · ½ · ⅔; dragged into an edge, the pane there closes the same way it came.
/// Pencil writes in either pane; the pane last touched has focus (the tools capsule's popovers, keyboard
/// shortcuts, opening from the library). Focus mode hides both bars. Compact chrome shows the focused
/// pane alone.
///
/// Interactive dismissal: the library pushes the editor with a zoom transition whose swipe-down / pinch
/// dismissal would fight Pencil strokes and scrolling. `.interactiveDismissDisabled()` doesn't reach it, so
/// `CanvasHostView` disables those recognizers while it's on screen (edge swipe stays, fingers only);
/// leaving is the back button or the edge swipe.
struct EditorScreen: View {
    /// The editor's coordinate space (the divider's drag).
    static let space = "editor"

    let library: any LibraryModel
    let tools: ToolState
    let tabs: TabsModel
    let sessions: SessionStore
    let startsFocused: Bool

    /// Split view's moves and their animated state.
    @State private var split: SplitController
    /// Each pane's bar height, measured (the tools capsule docks under the top one).
    @State private var barHeights: [OpenTabs.Pane: CGFloat] = [:]
    @State private var size: CGSize = .zero
    /// A tab dragged over the page: the half it would land on.
    @State private var dropSide: OpenTabs.Pane?
    @AppStorage(SettingsView.snapsShapesKey) private var snapsShapes = true
    @AppStorage(SettingsView.holdsToEraseKey) private var holdsToErase = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chromeLayout) private var chrome

    /// A pane on screen.
    private struct Entry: Identifiable {
        let session: NotebookSession
        let notebook: NotebookSummary
        /// Where the layout puts it.
        let side: OpenTabs.Pane
        /// The tabs pane it shows; `nil` while it slides away.
        let pane: OpenTabs.Pane?

        var id: ObjectIdentifier {
            ObjectIdentifier(session)
        }
    }

    init(library: any LibraryModel, tools: ToolState, tabs: TabsModel, sessions: SessionStore, startsFocused: Bool = false) {
        self.library = library
        self.tools = tools
        self.tabs = tabs
        self.sessions = sessions
        self.startsFocused = startsFocused
        _split = State(initialValue: SplitController(tabs: tabs, sessions: sessions))
    }

    /// The split as on screen: compact chrome shows one pane.
    private var isSplit: Bool {
        tabs.isSplit && !chrome.isCompact
    }

    var body: some View {
        let entries = entries
        let focused = entries.first { $0.pane == (isSplit ? tabs.focus : entries.first?.pane) } ?? entries.first
        let isFocusMode = focused?.session.state.isFocused ?? false
        let chromeHidden = entries.contains { [.opening, .open].contains($0.session.state.pages.phase) }
        let geometry = SplitGeometry(size: size)
        ZStack {
            Rectangle().fill(Tokens.Colors.desk).ignoresSafeArea()
            let shown = isSplit || split.isBusy
            SplitPaneLayout(fraction: split.fraction, presence: shown ? split.presence : 0, mover: split.mover) {
                ForEach(entries) { entry in
                    pane(entry, geometry: geometry, isFocusMode: isFocusMode)
                        .layoutValue(key: SplitSlot.self, value: .pane(entry.side))
                        .zIndex(entry.side == split.mover ? 1 : 0)
                        .opacity(split.opacity(of: entry.side, in: size))
                        .allowsHitTesting(entry.pane != nil)
                        .transition(.identity)
                }
                if shown {
                    divider(geometry)
                        .layoutValue(key: SplitSlot.self, value: .divider)
                        .zIndex(2)
                }
            }
            .coordinateSpace(.named(Self.space))
            .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            .onDrop(of: [.notebookReference], delegate: TabDrop(
                geometry: geometry, isEnabled: !tabs.isSplit && !chrome.isCompact && !split.isBusy, side: $dropSide
            ) { id, side in
                split.open(id, beside: .primary, on: side, showing: showing)
            })
            if let dropSide {
                TabDropZone(
                    geometry: geometry, side: dropSide,
                    title: NotebookReference.dragged.flatMap { library.notebook(id: $0)?.title }
                )
            }
            if let focused {
                tools(for: focused, isFocusMode: isFocusMode, hidden: chromeHidden)
            }
        }
        .animation(reduceMotion ? Tokens.Motion.reducedMorph : Tokens.Motion.morph, value: isFocusMode)
        .onChange(of: reduceMotion, initial: true) { _, reduce in split.reduceMotion = reduce }
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(isFocusMode ? .hidden : .automatic)
        .task(id: tabs.ids) {
            tabs.prune(keeping: Set(library.notebooks.map(\.id)))
            // A notebook lives in one window: its tab here goes if another window has it open (#175).
            for id in tabs.ids where AppWindows.window(holding: id, besides: sessions) != nil {
                tabs.close(id)
            }
        }
        .onChange(of: tabs.active) { _, id in
            if id == nil {
                dismiss()
            }
        }
        // Focus mode is the editor's: entering or leaving it in one pane does it in both.
        .onChange(of: entries.map(\.session.state.isFocused)) { old, new in
            let on = zip(old, new).contains { !$0 && $1 }, off = zip(old, new).contains { $0 && !$1 }
            for entry in entries {
                if on {
                    entry.session.state.enterFocus()
                } else if off {
                    entry.session.state.exitFocus()
                }
            }
        }
        .onChange(of: tools.active) { _, tool in
            for entry in entries {
                entry.session.setTool(
                    tool, allowsFingerDrawing: LaunchOptions.allowsFingerDrawing, snapsShapes: snapsShapes, holdsToErase: holdsToErase
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                sessions.flushAll()
            }
        }
        .onDisappear { sessions.closeAll() }
    }

    // MARK: Panes

    /// What's on screen: the panes the tabs show, and one sliding away.
    private var entries: [Entry] {
        if let closing = split.closing {
            // Until the slide ends, the staying pane keeps its side.
            return [entry(.primary, side: closing.side.other), Entry(
                session: closing.session, notebook: closing.notebook, side: closing.side, pane: nil
            )].compactMap(\.self)
        }
        if isSplit {
            return [entry(.primary, side: .primary), entry(.secondary, side: .secondary)].compactMap(\.self)
        }
        let shown = tabs.isSplit ? tabs.focus : .primary
        return [entry(shown, side: .primary)].compactMap(\.self)
    }

    private func entry(_ pane: OpenTabs.Pane, side: OpenTabs.Pane) -> Entry? {
        guard let id = tabs.showing(pane), let notebook = library.notebook(id: id),
              AppWindows.window(holding: id, besides: sessions) == nil else { return nil }
        let session = sessions.session(for: notebook, in: pane, startsFocused: startsFocused && pane == .primary)
        return Entry(session: session, notebook: notebook, side: side, pane: pane)
    }

    private func pane(_ entry: Entry, geometry: SplitGeometry, isFocusMode: Bool) -> some View {
        let pane = entry.pane ?? entry.side
        // Panes along the top edge keep room for the tools capsule docked there.
        let isAtTop = !isSplit || entry.side == .primary || geometry.axis == .horizontal
        let capsuleRoom: CGFloat = tools.dock == .top && isAtTop && !chrome.isCompact ? 72 : 0
        return EditorPane(
            pane: pane, session: entry.session, notebook: entry.notebook, library: library, tools: tools, tabs: tabs,
            isFocused: isFocusMode, capsuleRoom: capsuleRoom, isAtTop: isAtTop,
            fitDesk: isSplit && geometry.axis == .horizontal ? Self.splitDesk : CanvasHostView.defaultFitDesk,
            onBarHeight: { barHeights[pane] = $0 }, onBack: { dismiss() }, onCloseTab: closeTab,
            actions: SplitActions(
                open: { split.open($0, beside: pane, showing: showing) },
                closePane: { closePane(pane) },
                swap: { split.swap(showing: showing) }
            )
        )
    }

    /// Desk each side of a fitted page in a side-by-side pane: the page keeps most of its width.
    private static let splitDesk: CGFloat = 32

    /// The tools capsule, for the focused pane.
    private func tools(for entry: Entry, isFocusMode: Bool, hidden: Bool) -> some View {
        let viewport = entry.session.host.state
        let page = (min(viewport.currentPage + 1, max(viewport.pageCount, 1)), viewport.pageCount)
        return Group {
            if !hidden {
                ToolbarHost(
                    tools: tools, state: entry.session.state, paper: entry.notebook.theme.style, page: page,
                    topInset: isFocusMode ? 0 : barHeights[.primary] ?? 0
                )
                .transition(.opacity)
            }
        }
        .animation(FlightTiming.segment(0, 0.3, opening: hidden, reduceMotion: reduceMotion), value: hidden)
    }

    private func divider(_ geometry: SplitGeometry) -> some View {
        let settled = isSplit && !split.isBusy
        return SplitDivider(
            axis: geometry.axis, stop: split.stop, isDragging: split.isDragging, fraction: split.fraction,
            onChanged: { split.drag(to: $0, in: size, showing: showing) },
            onEnded: { position, velocity in
                split.release(at: position, velocity: velocity, in: size, showing: showing) { closePane($0) }
            },
            onSwap: { split.swap(showing: showing) },
            onAdjust: { split.adjust($0, showing: showing) }
        )
        .opacity(settled ? 1 : 0)
        // Last in, first out.
        .animation(settled ? .easeOut(duration: 0.2).delay(0.3) : .easeOut(duration: 0.1), value: settled)
        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.3)), removal: .identity))
        .allowsHitTesting(!split.isBusy)
    }

    /// The sessions on screen.
    private var showing: [NotebookSession] {
        entries.map(\.session)
    }

    /// `pane` slides away; `then` runs once it's gone.
    private func closePane(_ pane: OpenTabs.Pane, then: @escaping () -> Void = {}) {
        guard let id = tabs.showing(pane), let notebook = library.notebook(id: id) else { return then() }
        split.close(pane, notebook: notebook, showing: showing, then: then)
    }

    // MARK: Tabs

    /// A tab showing in one pane of a split closes with that pane sliding away; otherwise at once.
    private func closeTab(_ id: NotebookID) {
        let panes = [OpenTabs.Pane.primary, .secondary].filter { tabs.showing($0) == id }
        if isSplit, panes.count == 1, let pane = panes.first {
            return closePane(pane) {
                sessions.close(id)
                tabs.close(id)
            }
        }
        // The unfolded strip stays unfolded on the tab that shows next.
        let unfolded = entries.first?.session.state.showsTabs ?? false
        sessions.close(id)
        tabs.close(id)
        entry(.primary, side: .primary)?.session.state.setTabs(unfolded: unfolded)
    }
}

/// Preview tabs: the sample library's notebooks, `index` showing (beside `split`, if given).
@MainActor
private func previewTabs(_ library: SampleLibrary, showing index: Int, split: Int? = nil) -> TabsModel {
    let tabs = TabsModel(defaults: UserDefaults(suiteName: "preview") ?? .standard)
    for notebook in library.notebooks.prefix(3) {
        tabs.open(notebook.id)
    }
    tabs.open(library.notebooks[index].id)
    if let split {
        tabs.openSplit(library.notebooks[split].id)
    }
    return tabs
}

#Preview("Editor · light") {
    let library = SampleLibrary()
    let tools = ToolState(initial: .notespace)
    EditorScreen(
        library: library, tools: tools, tabs: previewTabs(library, showing: 0), sessions: SessionStore(library: library, tools: tools)
    )
}

#Preview("Editor · split") {
    let library = SampleLibrary()
    let tools = ToolState(initial: .notespace)
    EditorScreen(
        library: library, tools: tools, tabs: previewTabs(library, showing: 0, split: 1),
        sessions: SessionStore(library: library, tools: tools)
    )
}

#Preview("Editor · focus · dark") {
    let library = SampleLibrary()
    let tools = ToolState(initial: .notespace)
    EditorScreen(
        library: library, tools: tools, tabs: previewTabs(library, showing: 3), sessions: SessionStore(library: library, tools: tools),
        startsFocused: true
    )
    .preferredColorScheme(.dark)
}
