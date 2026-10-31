import DesignSystem
import SwiftUI
import Sync
import UniformTypeIdentifiers

/// Settings › Sync (#225 mocks 01, 02; #228): the demo row, with "Choose Folder…" until there is a folder; then
/// the folder (Change Folder… / Stop Syncing), a progress row while sending or receiving, Sync Now, Devices ›.
/// The footer says how it stands.
struct SyncSettingsSection: View {
    let sync: SyncModel

    @State private var picksFolder = false

    var body: some View {
        Section {
            SettingRow(.sync, "Sync", "Pick a folder in Files. Every device that uses it keeps the same notebooks.") {
                if sync.folderName == nil {
                    Button("Choose Folder…") { picksFolder = true }
                        .accessibilityIdentifier("chooseSyncFolder")
                }
            }
            if let name = sync.folderName {
                folderRow(name)
                switch sync.status {
                case let .sending(progress), let .receiving(progress):
                    progressRow(progress)
                default:
                    EmptyView()
                }
                Button("Sync Now") { sync.syncNow() }
                    .disabled(sync.isSyncing)
                    .accessibilityIdentifier("syncNow")
                NavigationLink(value: SettingsRoute.devices) {
                    LabeledContent("Devices") {
                        Text(sync.deviceCount > 0 ? "\(sync.deviceCount)" : "")
                    }
                }
                .foregroundStyle(Tokens.Colors.textPrimary)
                .accessibilityIdentifier("syncDevices")
            }
        } header: {
            Text("Sync")
        } footer: {
            // Ticks so "2 minutes ago" stays true while Settings is open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(footer(now: context.date))
                    .accessibilityIdentifier("syncFooter")
            }
        }
        .fileImporter(isPresented: $picksFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                sync.choose(url)
            }
        }
    }

    private func folderRow(_ name: String) -> some View {
        Menu {
            Button("Change Folder…", systemImage: "folder") { picksFolder = true }
            Button("Stop Syncing", systemImage: "xmark.circle", role: .destructive) { sync.stop() }
        } label: {
            HStack(spacing: Tokens.Spacing.s) {
                Text("Folder")
                    .foregroundStyle(Tokens.Colors.textPrimary)
                Spacer(minLength: Tokens.Spacing.m)
                Text(name)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Tokens.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .accessibilityLabel("Folder")
        .accessibilityValue(name)
        .accessibilityIdentifier("syncFolder")
    }

    /// "Sending Thermodynamics…" / "2 pages", or "Updating from Abhey’s iPhone…" / "Linear Algebra · 3 of 7
    /// pages", over a 3 pt hairline.
    private func progressRow(_ progress: SyncProgress) -> some View {
        let sending = progress.direction == .sending
        let title = sending
            ? "Sending \(progress.notebook)…"
            : progress.device.map { "Updating from \($0)…" } ?? "Updating \(progress.notebook)…"
        let detail = sending
            ? EditedLabel.pages(progress.total)
            : "\(progress.notebook) · \(progress.done) of \(EditedLabel.pages(progress.total))"
        let fraction = sending
            ? Double(progress.done) / Double(max(progress.done + progress.total, 1))
            : Double(progress.done) / Double(max(progress.total, 1))
        return VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
            Text(detail)
                .scaledFont(size: 13)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .lineLimit(1)
            Hairline(fraction: fraction, height: 3)
                .padding(.top, 5)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("syncProgress")
    }

    private func footer(now: Date) -> String {
        switch sync.status {
        case .off:
            "iCloud Drive, Google Drive, Dropbox… any folder in Files works. Nothing to sign in to."
        case let .idle(summary):
            if let last = summary.last {
                "Up to date · \(Self.ago(last, now: now)). Changes you make here appear on your other devices as soon as "
                    + "the folder catches up."
            } else {
                "Changes you make here appear on your other devices as soon as the folder catches up."
            }
        case .sending:
            "Only the pages you changed are sent. Writing is never interrupted."
        case .receiving:
            "Open notebooks finish updating when you close them."
        case let .uploading(pending):
            pending > 0
                ? "Sent. iCloud Drive is still uploading \(EditedLabel.notebooks(pending)); other devices see them once it finishes."
                : "Sent. iCloud Drive is still uploading; other devices see the changes once it finishes."
        case .folderUnavailable:
            "The sync folder was moved or deleted. Choose it again to continue."
        case let .failed(message):
            message
        }
    }

    /// "just now", "2 minutes ago", "yesterday".
    static func ago(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : date.formatted(.relative(presentation: .named))
    }
}

/// Settings pushes (inside its `NavigationStack`).
enum SettingsRoute: Hashable {
    case devices
}

/// A thin determinate bar: track and blue fill, rounded (no spinners, §1.4).
struct Hairline: View {
    var fraction: Double
    var height: CGFloat = 2

    var body: some View {
        Capsule()
            .fill(Tokens.Colors.separator)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Tokens.Colors.selection)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .clipShape(.capsule)
            .frame(height: height)
            .animation(.easeOut(duration: 0.25), value: fraction)
            .accessibilityHidden(true)
    }
}
