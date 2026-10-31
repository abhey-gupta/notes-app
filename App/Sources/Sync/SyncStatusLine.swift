import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// Beside the library title, on its baseline (#225 mock 03, moved off the line below: anything under the
/// title grows the bar or drags its scroll-edge effect down): "Sending Thermodynamics · 2 pages" or "Updating
/// from iPhone · 3 of 7 pages" in caption grey with a 120 pt hairline, then "Synced just now" or "Updated from
/// iPhone" for 2 s, then it fades. Nothing when idle or off. It gives way before the title does.
struct SyncStatusLine: View {
    @Environment(SyncModel.self) private var sync: SyncModel?

    var body: some View {
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
            .layoutPriority(-1)
            .transition(.opacity)
            .animation(.spring(duration: 0.35, bounce: 0), value: sync?.line == nil)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("syncStatus")
        }
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
/// line. While an empty library adopts the folder: nothing (``AdoptCard`` is over it, the library fills in).
/// With no folder chosen: "Already using Notespace? Choose your sync folder", which opens the Files picker.
struct SyncEmptyState<Fallback: View>: View {
    let applies: Bool
    @ViewBuilder let fallback: Fallback

    @Environment(SyncModel.self) private var sync: SyncModel?
    @State private var picksFolder = false

    var body: some View {
        if applies, let sync, sync.adoption != nil {
            Color.clear
                .frame(height: 1)
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

/// A fresh library adopting the folder (mock 04 left): centred over the library, which fills behind it; cloud
/// glyph, "Bringing in 14 notebooks", "From ‹device›, via ‹provider›. You can start writing meanwhile.", a
/// 220 pt hairline (pages written) and "4 of 14". It goes once adopt finishes; never shows for an empty folder.
struct AdoptCard: View {
    @Environment(SyncModel.self) private var sync: SyncModel?

    var body: some View {
        ZStack {
            if let sync, let adoption = sync.adoption {
                card(adoption, provider: sync.providerName)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.35, bounce: 0), value: sync?.adoption == nil)
    }

    private func card(_ adoption: Adoption, provider: String?) -> some View {
        VStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "icloud")
                .scaledFont(size: 30, weight: .regular)
                .foregroundStyle(Tokens.Colors.pillText)
                .accessibilityHidden(true)
            Text("Bringing in \(EditedLabel.notebooks(adoption.total))")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .padding(.top, 6)
            Text(Self.detail(device: adoption.device, provider: provider))
                .scaledFont(size: 14)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, Tokens.Spacing.s)
            Hairline(fraction: adoption.fraction, height: 3)
                .frame(width: 220)
            Text("\(min(adoption.done, adoption.total)) of \(adoption.total)")
                .scaledFont(size: 12.5)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 26)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(maxWidth: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("adoptCard")
    }

    /// "From Abhey’s iPad Pro, via iCloud Drive. You can start writing meanwhile."
    static func detail(device: String?, provider: String?) -> String {
        let via = [device.map { "From \($0)" }, provider.map { device == nil ? "Via \($0)" : "via \($0)" }]
            .compactMap(\.self).joined(separator: ", ")
        return via.isEmpty ? "You can start writing meanwhile." : "\(via). You can start writing meanwhile."
    }
}
