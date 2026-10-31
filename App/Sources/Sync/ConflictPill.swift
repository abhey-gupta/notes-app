import DesignSystem
import Document
import InkModel
import SwiftUI
import Sync

/// A pane's sync conflicts (#225, mock 05 C): the replaced versions of its notebook's pages as ghost ink
/// (``NotebookSession/setGhosts(_:)``), and the pill at the bottom centre while such a page is the current
/// one. Nothing here blocks the Pencil: the pill is the only thing that takes touches.
struct ConflictLayer: View {
    let session: NotebookSession

    @Environment(SyncModel.self) private var sync: SyncModel?
    /// Replaced versions read from the folder, by page.
    @State private var replaced: [PageID: PageContent] = [:]
    @State private var keeping = false

    var body: some View {
        let conflicts = sync?.conflicts(in: session.notebookID) ?? []
        let shown = currentPage.flatMap { page in conflicts.first { $0.page == page } }
        ZStack {
            if let sync, let shown {
                ConflictPill(device: sync.device(of: shown), canKeep: replaced[shown.page] != nil && !keeping) {
                    keep(shown, sync: sync)
                } dismiss: {
                    sync.dismiss(shown)
                }
                .onAppear { sync.conflictShown(shown) }
                .transition(.opacity.combined(with: .offset(y: 12)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 22)
        .animation(.spring(duration: 0.35, bounce: 0), value: shown)
        .task(id: conflicts) { await loadGhosts(conflicts) }
        .onDisappear { session.setGhosts([:]) }
    }

    /// The page the pane shows (its real ID once the manifest is read).
    private var currentPage: PageID? {
        let index = session.host.state.currentPage
        let entries = session.state.pages.entries
        return entries.indices.contains(index) ? entries[index].id : nil
    }

    /// Reads each conflict's replaced version and shows its strokes as ghost ink (pages without a conflict
    /// any more lose theirs, fading).
    private func loadGhosts(_ conflicts: [Conflict]) async {
        guard let sync else { return }
        var loaded: [PageID: PageContent] = [:]
        for conflict in conflicts {
            if let content = replaced[conflict.page] {
                loaded[conflict.page] = content
            } else if let content = await sync.replacedContent(of: conflict) {
                loaded[conflict.page] = content
            }
        }
        guard !Task.isCancelled else { return }
        replaced = loaded
        session.setGhosts(loaded.mapValues(\.strokes))
    }

    /// Keep mine: the page shows the replaced version at once; sync sends it.
    private func keep(_ conflict: Conflict, sync: SyncModel) {
        guard let content = replaced[conflict.page] else { return }
        keeping = true
        Task {
            defer { keeping = false }
            guard let rev = await session.keepMine(content, on: conflict.page) else { return }
            sync.keepMine(conflict, rev: rev)
        }
    }
}

/// "[iPhone] Replaced by the iPhone version  [Keep mine]  ×" in the chrome's glass (mock 05 A/C).
struct ConflictPill: View {
    let device: SyncDevice
    let canKeep: Bool
    let keep: () -> Void
    let dismiss: () -> Void

    var body: some View {
        GlassCapsule(height: Tokens.Size.focusPillHeight, leading: Tokens.Spacing.l, trailing: Tokens.Spacing.xs, spacing: 14) {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: device.glyph)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Tokens.Colors.icon)
                    .accessibilityHidden(true)
                Text("Replaced by the \(device.name) version")
                    .scaledFont(size: 15)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("conflictMessage")
            Button(action: keep) {
                Text("Keep mine")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(Tokens.Colors.selection)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .background(Tokens.Colors.selection.opacity(0.08), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .disabled(!canKeep)
            .accessibilityIdentifier("keepMine")
            .accessibilityHint("Brings back your version of this page; the other version is drawn in blue")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Colors.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("dismissConflict")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conflictPill")
    }
}
