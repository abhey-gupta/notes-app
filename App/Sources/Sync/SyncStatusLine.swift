import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// Under the library title while sync sends, receives or uploads (#174 mock 05-D, #225 mock 03): "Sending
/// Thermodynamics · 2 pages" or "Updating from iPhone · 3 of 7 pages" in caption grey with a 120 pt hairline,
/// then "Synced just now" or "Updated from iPhone" for 2 s, then it folds away. Nothing when idle or off.
struct SyncStatusLine: View {
    @Environment(SyncModel.self) private var sync: SyncModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let line = sync?.line {
                HStack(spacing: 10) {
                    Text(text(line))
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                        .lineLimit(1)
                    if case let .progress(_, fraction) = line {
                        Hairline(fraction: fraction)
                            .frame(width: 120)
                    }
                }
                .padding(.top, 6)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("syncStatus")
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0), value: sync?.line == nil)
    }

    private func text(_ line: SyncModel.Line) -> String {
        switch line {
        case let .progress(text, _): text
        case .done: "Synced just now"
        case let .updated(device): "Updated from \(device)"
        }
    }
}

/// The library's empty state on All Notebooks with no search (`applies`), mock 04: `fallback`, then one caption
/// line. While an empty library adopts the folder: "Bringing in N notebooks…" instead of `fallback` (the glass
/// card is #225 PR 3). With no folder chosen: "Already using Notespace? Choose your sync folder", which opens
/// the Files picker.
struct SyncEmptyState<Fallback: View>: View {
    let applies: Bool
    @ViewBuilder let fallback: Fallback

    @Environment(SyncModel.self) private var sync: SyncModel?
    @State private var picksFolder = false

    var body: some View {
        if applies, let sync, let count = sync.adopting {
            Text("Bringing in \(EditedLabel.notebooks(count))…")
                .scaledFont(size: 15)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Tokens.Spacing.xxxl)
                .accessibilityIdentifier("adoptCaption")
        } else if applies, let sync, !sync.hasFolder {
            VStack(alignment: .leading, spacing: 14) {
                fallback
                Button {
                    picksFolder = true
                } label: {
                    Text("Already using Notespace? \(Text("Choose your sync folder").foregroundStyle(Tokens.Colors.selection))")
                        .scaledFont(size: 13)
                        .foregroundStyle(Tokens.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chooseSyncFolderCaption")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Tokens.Spacing.xxxl)
            .fileImporter(isPresented: $picksFolder, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result {
                    sync.choose(url)
                }
            }
        } else {
            fallback
                .padding(.vertical, Tokens.Spacing.xxxl)
        }
    }
}
